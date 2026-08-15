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
           pre_tick_systems: [MyGame.InputSystem],
           systems: [MyGame.MovementSystem],
           post_tick_systems: [MyGame.ReplicationSystem],
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
    * `:pre_tick_systems` - systems executed before `:systems` on every tick
    * `:post_tick_systems` - systems executed after `:systems` on every tick
    * `:shutdown_systems` - systems executed sequentially when the partition
      terminates gracefully
    * `:interval` - milliseconds between scheduled ticks; `0` runs without an
      intentional delay
    * `:tick_mode` - `:continuous` (default) keeps the fixed interval;
      `:on_demand` sleeps until an event, `wake/1`, or a system
      `ElvenGard.ECS.System.schedule_after/2` request
    * `:initial_tick` - whether an on-demand partition runs once after startup;
      defaults to `true`
    * `:concurrency` - maximum concurrent systems; defaults to the number of
      online schedulers
    * `:event_source` - event source name or PID; defaults to the global source
    * `:system_timeout` - timeout for one execution; defaults to `:infinity`

  Pre-tick, tick, and post-tick systems are separated by phase barriers. Every
  callback receives its phase, previously emitted current-tick change sets,
  and ephemeral system outputs in the system context. Partitions emit bounded
  telemetry for complete ticks, phases, individual systems, and lifecycle
  operations. Event-driven system metadata contains the event module, never
  the event payload.

  """

  @behaviour GenServer

  require Logger

  alias ElvenGard.ECS.System, as: ECSSystem
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

  @doc "Wakes a partition without waiting for its next configured deadline."
  @spec wake(GenServer.server()) :: :ok
  def wake(pid) do
    GenServer.cast(pid, :wake)
  end

  ## GenServer behaviour

  @impl true
  def init({mod, opts}) do
    Process.flag(:trap_exit, true)

    {id, specs} = mod.setup(opts)

    systems = specs[:systems] || raise ArgumentError, ":systems is required"
    startup_systems = Keyword.get(specs, :startup_systems, [])
    pre_tick_systems = Keyword.get(specs, :pre_tick_systems, [])
    post_tick_systems = Keyword.get(specs, :post_tick_systems, [])
    shutdown_systems = Keyword.get(specs, :shutdown_systems, [])
    interval = Keyword.get(specs, :interval, 1_000)
    tick_mode = validate_tick_mode(Keyword.get(specs, :tick_mode, :continuous))
    initial_tick = Keyword.get(specs, :initial_tick, true)
    concurrency = Keyword.get(specs, :concurrency, System.schedulers_online())
    source = Keyword.get(specs, :event_source, EventSource.name())
    system_timeout = Keyword.get(specs, :system_timeout, :infinity)
    tick = now()

    state = %{
      id: id,
      prev_tick: tick,
      next_tick: tick,
      interval: interval,
      tick_mode: tick_mode,
      initial_tick: initial_tick,
      timer_ref: nil,
      tick_token: nil,
      scheduled_tick_at: nil,
      requested_delay: nil,
      startup_systems: startup_systems,
      pre_tick_systems: pre_tick_systems,
      post_tick_systems: post_tick_systems,
      shutdown_systems: shutdown_systems,
      systems: systems,
      concurrency: concurrency,
      source: source,
      system_timeout: system_timeout,
      events: [],
      receipts: [],
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
      context = build_context(id, :startup, :startup)
      metadata = %{system: module, partition: id, phase: :startup}

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

    metadata = %{
      id: id,
      partition: id,
      startup_systems: startup_systems,
      startup_system_count: length(startup_systems)
    }

    :telemetry.execute([:elvengard_ecs, :partition_init], measurements, metadata)

    {:noreply, state, {:continue, :subscribe_to_events}}
  end

  @impl true
  def handle_continue(:subscribe_to_events, %{id: id, source: source} = state) do
    :ok = EventSource.subscribe(source, partition: id)
    new_state = schedule_initial_tick(state)
    {:noreply, %{new_state | started: true}}
  end

  @impl true
  def handle_info(:tick, state) do
    {:noreply, state |> cancel_scheduled_tick() |> run_partition_tick()}
  end

  def handle_info({:tick, token}, %{tick_token: token} = state) do
    {:noreply, state |> clear_scheduled_tick() |> run_partition_tick()}
  end

  def handle_info({:tick, _stale_token}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast(:wake, state) do
    {:noreply, schedule_tick_in(state, 0)}
  end

  def handle_cast({:events, new_events}, %{events: events} = state) do
    state = %{state | events: [new_events | events]}
    {:noreply, wake_for_events(state)}
  end

  def handle_cast(
        {:tracked_events, receipt, source, new_events},
        %{events: events, receipts: receipts} = state
      ) do
    state = %{
      state
      | events: [new_events | events],
        receipts: [{source, receipt} | receipts]
    }

    {:noreply, wake_for_events(state)}
  end

  defp run_partition_tick(state) do
    metadata = %{partition: state.id}

    new_state =
      :telemetry.span([:elvengard_ecs, :partition_tick], metadata, fn ->
        {new_state, measurements} = run_tick(state)
        {new_state, measurements, metadata}
      end)

    schedule_after_tick(new_state)
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

  defp run_tick(state) do
    %{
      pre_tick_systems: pre_tick_systems,
      systems: systems,
      post_tick_systems: post_tick_systems,
      events: event_batches,
      receipts: receipts,
      prev_tick: prev_tick
    } = state

    tick = now()
    delta = tick - prev_tick

    events =
      case event_batches do
        [] -> []
        [events] -> events
        _ -> event_batches |> :lists.reverse() |> :lists.append()
      end

    {pre_tick_failures, change_sets, outputs, schedule_requests} =
      execute_phase(pre_tick_systems, events, state, delta, :pre_tick, [], [], [])

    {tick_failures, change_sets, outputs, schedule_requests} =
      execute_phase(
        systems,
        events,
        state,
        delta,
        :tick,
        change_sets,
        outputs,
        schedule_requests
      )

    {post_tick_failures, change_sets, outputs, schedule_requests} =
      execute_phase(
        post_tick_systems,
        events,
        state,
        delta,
        :post_tick,
        change_sets,
        outputs,
        schedule_requests
      )

    failures = pre_tick_failures ++ tick_failures ++ post_tick_failures

    failed_systems = failures |> Enum.map(&failed_system/1) |> Enum.uniq()
    acknowledge_receipts(receipts, failed_systems, state.id)

    new_state = %{
      state
      | events: [],
        receipts: [],
        prev_tick: tick,
        requested_delay: minimum_delay(schedule_requests)
    }

    measurements = %{
      event_count: length(events),
      failure_count: length(failed_systems),
      change_set_count: length(change_sets),
      output_count: length(outputs),
      schedule_request_count: length(schedule_requests),
      receipt_count: length(receipts)
    }

    {new_state, measurements}
  end

  defp now(), do: System.monotonic_time(:millisecond)

  defp build_context(partition, delta, phase, change_sets \\ [], outputs \\ []) do
    %{
      partition: partition,
      delta: delta,
      phase: phase,
      change_sets: change_sets,
      outputs: outputs
    }
  end

  defp build_shutdown_context(partition, reason) do
    %{
      partition: partition,
      delta: :shutdown,
      phase: :shutdown,
      reason: reason,
      change_sets: [],
      outputs: []
    }
  end

  defp execute_phase(
         systems,
         events,
         state,
         delta,
         phase,
         change_sets,
         outputs,
         schedule_requests
       ) do
    expanded_systems = Enum.flat_map(systems, &expand_with_events(&1, events))

    metadata = %{
      partition: state.id,
      phase: phase,
      configured_system_count: length(systems)
    }

    :telemetry.span([:elvengard_ecs, :phase_run], metadata, fn ->
      {failures, next_change_sets, next_outputs, next_schedule_requests} =
        batch_and_execute(
          expanded_systems,
          state,
          delta,
          phase,
          change_sets,
          outputs,
          schedule_requests
        )

      measurements = %{
        change_set_count: length(next_change_sets) - length(change_sets),
        event_count: length(events),
        failure_count: length(failures),
        output_count: length(next_outputs) - length(outputs),
        schedule_request_count: length(next_schedule_requests) - length(schedule_requests),
        system_run_count: length(expanded_systems)
      }

      {{failures, next_change_sets, next_outputs, next_schedule_requests}, measurements, metadata}
    end)
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
    state
    |> schedule_tick_in(max(remaining_time, 0))
    |> Map.put(:next_tick, time + remaining_time)
  end

  defp batch_and_execute(
         [],
         _state,
         _delta,
         _phase,
         change_sets,
         outputs,
         schedule_requests
       ) do
    {[], change_sets, outputs, schedule_requests}
  end

  defp batch_and_execute(
         systems,
         state,
         delta,
         phase,
         change_sets,
         outputs,
         schedule_requests
       ) do
    context = build_context(state.id, delta, phase, change_sets, outputs)
    systems = Enum.filter(systems, &ECSSystem.run?(failed_system(&1), context))

    do_batch_and_execute(
      systems,
      state,
      delta,
      phase,
      change_sets,
      outputs,
      schedule_requests
    )
  end

  defp do_batch_and_execute([], _state, _delta, _phase, change_sets, outputs, schedule_requests) do
    {[], change_sets, outputs, schedule_requests}
  end

  defp do_batch_and_execute(
         systems,
         state,
         delta,
         phase,
         change_sets,
         outputs,
         schedule_requests
       ) do
    %{
      id: id,
      concurrency: concurrency,
      system_timeout: system_timeout
    } = state

    {batch, remaining} = batch_systems(systems, concurrency)

    executions =
      batch
      |> Task.async_stream(
        &execute(&1, delta, id, phase, change_sets, outputs),
        max_concurrency: concurrency,
        ordered: true,
        timeout: system_timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    succeed =
      Enum.flat_map(executions, fn
        {:ok, {:system_succeeded, value, _result}} -> [value]
        _failed -> []
      end)

    emitted_change_sets =
      Enum.flat_map(executions, fn
        {:ok, {:system_succeeded, _value, result}} -> ECSSystem.emitted_change_sets(result)
        _failed -> []
      end)

    emitted_outputs =
      Enum.flat_map(executions, fn
        {:ok, {:system_succeeded, value, result}} ->
          case ECSSystem.emitted_output(result) do
            {:ok, output} -> [{failed_system(value), output}]
            :error -> []
          end

        _failed ->
          []
      end)

    emitted_schedule_requests =
      Enum.flat_map(executions, fn
        {:ok, {:system_succeeded, _value, result}} ->
          case ECSSystem.scheduled_after(result) do
            nil -> []
            delay -> [delay]
          end

        _failed ->
          []
      end)

    failed = batch -- succeed

    if failed != [] do
      Logger.error(fn ->
        "#{length(failed)} systems killed/crashed: #{inspect(failed, limit: :infinity)}"
      end)
    end

    {remaining_failures, change_sets, outputs, schedule_requests} =
      batch_and_execute(
        remaining,
        state,
        delta,
        phase,
        change_sets ++ emitted_change_sets,
        outputs ++ emitted_outputs,
        schedule_requests ++ emitted_schedule_requests
      )

    {failed ++ remaining_failures, change_sets, outputs, schedule_requests}
  end

  defp failed_system({system, _event}), do: system
  defp failed_system(system), do: system

  defp acknowledge_receipts([], _failed_systems, _partition), do: :ok

  defp acknowledge_receipts(receipts, failed_systems, partition) do
    Enum.each(receipts, fn {source, receipt} ->
      EventSource.ack(source, receipt, partition, failed_systems)
    end)
  end

  # System subscribing to events
  defp execute({system, event} = value, delta, partition, phase, change_sets, outputs) do
    context = build_context(partition, delta, phase, change_sets, outputs)
    metadata = %{partition: partition, system: system, event_type: event.__struct__, phase: phase}

    # Send Telemetry
    result =
      :telemetry.span(
        [:elvengard_ecs, :system_run],
        metadata,
        fn -> {system.run(event, context), metadata} end
      )

    {:system_succeeded, value, result}
  catch
    kind, payload ->
      exception = Exception.format(kind, payload, __STACKTRACE__)
      Logger.error("#{inspect(value)} system crashed with error:\n#{exception}")
      :error
  end

  # Permanents systems
  defp execute(system, delta, partition, phase, change_sets, outputs) do
    context = build_context(partition, delta, phase, change_sets, outputs)
    metadata = %{partition: partition, system: system, event_type: nil, phase: phase}

    # Send Telemetry
    result =
      :telemetry.span(
        [:elvengard_ecs, :system_run],
        metadata,
        fn -> {system.run(context), metadata} end
      )

    {:system_succeeded, system, result}
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

  defp schedule_initial_tick(%{tick_mode: :continuous} = state), do: schedule_next_tick(state)

  defp schedule_initial_tick(%{tick_mode: :on_demand, initial_tick: true} = state) do
    schedule_tick_in(state, 0)
  end

  defp schedule_initial_tick(%{tick_mode: :on_demand} = state), do: state

  defp schedule_after_tick(%{tick_mode: :continuous} = state) do
    state |> Map.put(:requested_delay, nil) |> schedule_next_tick()
  end

  defp schedule_after_tick(%{tick_mode: :on_demand, requested_delay: nil} = state), do: state

  defp schedule_after_tick(%{tick_mode: :on_demand, requested_delay: delay} = state) do
    state |> Map.put(:requested_delay, nil) |> schedule_tick_in(delay)
  end

  defp wake_for_events(%{tick_mode: :on_demand} = state), do: schedule_tick_in(state, 0)
  defp wake_for_events(state), do: state

  defp schedule_tick_in(state, delay) when is_integer(delay) and delay >= 0 do
    scheduled_at = now() + delay

    case state.scheduled_tick_at do
      nil -> replace_scheduled_tick(state, scheduled_at, delay)
      current when scheduled_at < current -> replace_scheduled_tick(state, scheduled_at, delay)
      _current -> state
    end
  end

  defp replace_scheduled_tick(state, scheduled_at, delay) do
    state = cancel_scheduled_tick(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, token}, delay)

    %{
      state
      | timer_ref: timer_ref,
        tick_token: token,
        scheduled_tick_at: scheduled_at
    }
  end

  defp cancel_scheduled_tick(%{timer_ref: nil} = state), do: clear_scheduled_tick(state)

  defp cancel_scheduled_tick(%{timer_ref: timer_ref} = state) do
    _remaining = Process.cancel_timer(timer_ref)
    clear_scheduled_tick(state)
  end

  defp clear_scheduled_tick(state) do
    %{state | timer_ref: nil, tick_token: nil, scheduled_tick_at: nil}
  end

  defp minimum_delay([]), do: nil
  defp minimum_delay(delays), do: Enum.min(delays)

  defp validate_tick_mode(mode) do
    case mode do
      :continuous ->
        :continuous

      :on_demand ->
        :on_demand

      value ->
        raise ArgumentError, ":tick_mode must be :continuous or :on_demand, got #{inspect(value)}"
    end
  end
end
