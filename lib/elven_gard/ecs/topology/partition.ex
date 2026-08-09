defmodule ElvenGard.ECS.Topology.Partition do
  @moduledoc """
  Runs systems for one logical partition of the game world.

  Define a partition with `use ElvenGard.ECS.Topology.Partition` and implement
  `setup/1`:

      defmodule MyGame.WorldPartition do
        use ElvenGard.ECS.Topology.Partition

        @impl true
        def setup(opts) do
          id = Keyword.fetch!(opts, :id)

          {id,
           systems: [MyGame.MovementSystem],
           startup_systems: [MyGame.LoadWorldSystem],
           shutdown_systems: [MyGame.UnloadWorldSystem],
           interval: 50}
        end
      end

  A partition executes startup systems, subscribes to its event source, and
  then schedules ticks. Systems are grouped into concurrent batches according
  to their component locks and the configured concurrency limit.

  Supported setup options are:

    * `:systems` - required list of regular systems
    * `:startup_systems` - systems executed once before event subscription
    * `:shutdown_systems` - systems executed sequentially when the partition
      terminates gracefully
    * `:interval` - milliseconds between scheduled ticks; `0` runs without an
      intentional delay
    * `:concurrency` - maximum concurrent systems; defaults to the number of
      online schedulers
    * `:event_source` - event source name or PID; defaults to the global source
    * `:system_timeout` - timeout for one execution; defaults to `:infinity`

  Partitions emit `:telemetry` spans under
  `[:elvengard_ecs, :startup_system_run]` and
  `[:elvengard_ecs, :shutdown_system_run]` and
  `[:elvengard_ecs, :system_run]`, plus `[:elvengard_ecs, :partition_init]`
  and `[:elvengard_ecs, :partition_shutdown]` lifecycle events.

  """

  @behaviour GenServer

  require Logger

  alias ElvenGard.ECS.Topology.EventSource

  ## Behaviour

  @typedoc "Application-defined partition identifier."
  @type id :: any()

  @typedoc "Partition identifier and runtime options returned by `setup/1`."
  @type partition_spec :: {id(), Keyword.t()}

  @doc "Builds the partition identifier and runtime options."
  @callback setup(opts :: Keyword.t()) :: partition_spec()

  ## Public API

  @doc false
  defmacro __using__(opts) do
    quote location: :keep do
      @behaviour unquote(__MODULE__)

      ## Public API

      def child_spec(opts) do
        default = %{
          id: {unquote(__MODULE__), make_ref()},
          start: {unquote(__MODULE__), :start_link, [{__MODULE__, opts}]},
          restart: :temporary
        }

        Supervisor.child_spec(default, unquote(Macro.escape(opts)))
      end
    end
  end

  @doc false
  def start_link({_mod, _opts} = specs) do
    GenServer.start_link(__MODULE__, specs)
  end

  @doc """
  Returns whether a partition completed startup and subscribed to its event
  source.
  """
  @spec started?(GenServer.server(), timeout()) :: boolean()
  def started?(pid, timeout \\ 5000) do
    GenServer.call(pid, :started?, timeout)
  end

  ## GenServer behaviour

  @impl true
  def init({mod, opts}) do
    Process.flag(:trap_exit, true)

    {id, specs} = mod.setup(opts)

    systems = specs[:systems] || raise ArgumentError, ":systems is required"
    startup_systems = Keyword.get(specs, :startup_systems, [])
    shutdown_systems = Keyword.get(specs, :shutdown_systems, [])
    interval = Keyword.get(specs, :interval, 1_000)
    concurrency = Keyword.get(specs, :concurrency, System.schedulers_online())
    source = Keyword.get(specs, :event_source, EventSource.name())
    system_timeout = Keyword.get(specs, :system_timeout, :infinity)
    tick = now()

    state = %{
      id: id,
      prev_tick: tick,
      next_tick: tick,
      interval: interval,
      startup_systems: startup_systems,
      shutdown_systems: shutdown_systems,
      systems: systems,
      concurrency: concurrency,
      source: source,
      system_timeout: system_timeout,
      events: [],
      started: false
    }

    {:ok, state, {:continue, :run_startup_systems}}
  end

  @impl true
  def handle_continue(:run_startup_systems, state) do
    %{id: id, startup_systems: startup_systems} = state
    start_time = System.monotonic_time()

    # Run all startup_systems
    Enum.each(startup_systems, fn module ->
      context = build_context(id, :startup)
      metadata = %{system: module, partition: id}

      # Send Telemetry
      :telemetry.span(
        [:elvengard_ecs, :startup_system_run],
        metadata,
        fn -> {module.run(context), metadata} end
      )
    end)

    # Send Telemetry
    duration = System.monotonic_time() - start_time
    measurements = %{duration: duration}
    metadata = %{id: id, startup_systems: startup_systems, state: state}
    :telemetry.execute([:elvengard_ecs, :partition_init], measurements, metadata)

    {:noreply, state, {:continue, :subscribe_to_events}}
  end

  @impl true
  def handle_continue(:subscribe_to_events, %{id: id, source: source} = state) do
    :ok = EventSource.subscribe(source, partition: id)
    new_state = schedule_next_tick(state)
    {:noreply, %{new_state | started: true}}
  end

  @impl true
  def handle_info(:tick, state) do
    %{systems: systems, events: event_batches, prev_tick: prev_tick} = state
    tick = now()
    delta = tick - prev_tick

    events =
      case event_batches do
        [] -> []
        [events] -> events
        _ -> event_batches |> :lists.reverse() |> :lists.append()
      end

    systems
    |> Enum.flat_map(&expand_with_events(&1, events))
    |> batch_and_execute(state, delta)

    new_state = %{state | events: [], prev_tick: tick}
    {:noreply, schedule_next_tick(new_state)}
  end

  @impl true
  def handle_cast({:events, new_events}, %{events: events} = state) do
    {:noreply, %{state | events: [new_events | events]}}
  end

  @impl true
  def handle_call(:started?, _from, %{started: started} = state) do
    {:reply, started, state}
  end

  @impl true
  def terminate(reason, state) do
    %{id: id, shutdown_systems: shutdown_systems} = state
    start_time = System.monotonic_time()
    context = build_shutdown_context(id, reason)

    Enum.each(shutdown_systems, &run_shutdown_system(&1, context))

    measurements = %{duration: System.monotonic_time() - start_time}
    metadata = %{id: id, reason: reason, shutdown_systems: shutdown_systems}
    :telemetry.execute([:elvengard_ecs, :partition_shutdown], measurements, metadata)

    :ok
  end

  ## Internal use ONLY

  @doc false
  def expand_with_events(system, events) do
    maybe_system = if system.__run_each_frames__(), do: [system], else: []

    maybe_events =
      case system.__event_subscriptions__() do
        [] ->
          []

        subs ->
          events
          |> Enum.filter(&(&1.__struct__ in subs))
          |> Enum.map(&{system, &1})
      end

    Enum.concat(maybe_system, maybe_events)
  end

  ## Private functions

  defp now(), do: System.monotonic_time(:millisecond)

  defp build_context(partition, delta), do: %{partition: partition, delta: delta}

  defp build_shutdown_context(partition, reason) do
    %{partition: partition, delta: :shutdown, reason: reason}
  end

  defp run_shutdown_system(module, context) do
    metadata = %{
      partition: context.partition,
      reason: context.reason,
      system: module
    }

    :telemetry.span(
      [:elvengard_ecs, :shutdown_system_run],
      metadata,
      fn -> {module.run(context), metadata} end
    )
  catch
    kind, payload ->
      exception = Exception.format(kind, payload, __STACKTRACE__)

      Logger.error(
        "shutdown system failed system=#{inspect(module)} " <>
          "partition=#{inspect(context.partition)} reason=#{inspect(context.reason)}:\n#{exception}"
      )

      :error
  end

  defp schedule_next_tick(state) do
    %{next_tick: next_tick, interval: interval} = state
    time = now()

    remaining_time = next_tick + interval - time

    # Sleep until next tick
    case remaining_time > 0 do
      true -> Process.send_after(self(), :tick, remaining_time)
      false -> send(self(), :tick)
    end

    %{state | next_tick: time + remaining_time}
  end

  defp batch_and_execute([], _state, _delta), do: :ok

  defp batch_and_execute(systems, state, delta) do
    %{
      id: id,
      concurrency: concurrency,
      system_timeout: system_timeout
    } = state

    {batch, remaining} = batch_systems(systems, concurrency)

    succeed =
      batch
      |> Task.async_stream(
        &execute(&1, delta, id),
        max_concurrency: concurrency,
        ordered: false,
        timeout: system_timeout,
        on_timeout: :kill_task
      )
      |> Stream.filter(&match?({:ok, _}, &1))
      |> Enum.to_list()
      |> Enum.map(&elem(&1, 1))

    failed = batch -- succeed

    if failed != [] do
      Logger.error(fn ->
        "#{length(failed)} systems killed/crashed: #{inspect(failed, limit: :infinity)}"
      end)
    end

    batch_and_execute(remaining, state, delta)
  end

  # System subscribing to events
  defp execute({system, event} = value, delta, partition) do
    context = build_context(partition, delta)
    metadata = %{partition: partition, system: system, event: event}

    # Send Telemetry
    :telemetry.span(
      [:elvengard_ecs, :system_run],
      metadata,
      fn -> {system.run(event, context), metadata} end
    )

    value
  catch
    kind, payload ->
      exception = Exception.format(kind, payload, __STACKTRACE__)
      Logger.error("#{inspect(value)} system crashed with error:\n#{exception}")
      :error
  end

  # Permanents systems
  defp execute(system, delta, partition) do
    context = build_context(partition, delta)
    metadata = %{partition: partition, system: system, event: nil}

    # Send Telemetry
    :telemetry.span(
      [:elvengard_ecs, :system_run],
      metadata,
      fn -> {system.run(context), metadata} end
    )

    system
  catch
    kind, payload ->
      exception = Exception.format(kind, payload, __STACKTRACE__)
      Logger.error("#{inspect(system)} system crashed with error:\n#{exception}")
      :error
  end

  defp batch_systems(systems, counter, acc \\ [], next \\ [], components \\ MapSet.new())

  defp batch_systems([], _counter, acc, next, _components) do
    {:lists.reverse(acc), :lists.reverse(next)}
  end

  defp batch_systems(remaining, 0, acc, next, _components) do
    {:lists.reverse(acc), :lists.reverse(next) ++ remaining}
  end

  defp batch_systems([{system, _event} = value | remaining], counter, acc, next, components) do
    case batch(system, components, acc == []) do
      :sync ->
        batch_systems(remaining, 0, [value | acc], next, components)

      :next ->
        batch_systems(remaining, counter, acc, [value | next], components)

      {:ok, new_components} ->
        components = Enum.reduce(new_components, components, &MapSet.put(&2, &1))
        batch_systems(remaining, counter - 1, [value | acc], next, components)
    end
  end

  defp batch_systems([system | remaining], counter, acc, next, components) do
    case batch(system, components, acc == []) do
      :sync ->
        batch_systems(remaining, 0, [system | acc], next, components)

      :next ->
        batch_systems(remaining, counter, acc, [system | next], components)

      {:ok, new_components} ->
        components = Enum.reduce(new_components, components, &MapSet.put(&2, &1))
        batch_systems(remaining, counter - 1, [system | acc], next, components)
    end
  end

  defp batch(system, components, batch_empty?) do
    case {system.__lock_components__(), batch_empty?} do
      {:sync, true} ->
        :sync

      {:sync, false} ->
        :next

      {lock_components, _} ->
        case Enum.all?(lock_components, &(not MapSet.member?(components, &1))) do
          true -> {:ok, lock_components}
          false -> :next
        end
    end
  end
end
