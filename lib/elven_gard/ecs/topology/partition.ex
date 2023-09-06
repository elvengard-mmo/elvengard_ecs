defmodule ElvenGard.ECS.Topology.Partition do
  @moduledoc """
  TODO: ElvenGard.ECS.Topology.Partition
  """

  @behaviour GenServer

  require Logger

  alias ElvenGard.ECS.Topology.EventSource

  ## Behaviour

  @type id :: any()
  @type partition_spec :: {id(), Keyword.t()}
  @callback setup(opts :: Keyword.t()) :: partition_spec()

  ## Public API

  @doc false
  defmacro __using__(_env) do
    quote location: :keep do
      @behaviour unquote(__MODULE__)

      ## Public API

      def child_spec(opts) do
        %{
          id: unquote(__MODULE__),
          start: {unquote(__MODULE__), :start_link, [{__MODULE__, opts}]},
          restart: :temporary
        }
      end
    end
  end

  @doc false
  def start_link({_mod, _opts} = specs) do
    GenServer.start_link(__MODULE__, specs)
  end

  ## GenServer behaviour

  @impl true
  def init({mod, opts}) do
    {id, specs} = mod.setup(opts)

    systems = specs[:systems] || raise ArgumentError, ":systems is required"
    interval = Keyword.get(specs, :interval, 1_000)
    concurrency = Keyword.get(specs, :concurrency, System.schedulers_online())
    source = Keyword.get(specs, :event_source, EventSource.name())
    system_timeout = Keyword.get(specs, :system_timeout, :infinity)

    state = %{
      id: id,
      prev_tick: now(),
      interval: interval,
      systems: systems,
      concurrency: concurrency,
      source: source,
      system_timeout: system_timeout,
      events: []
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, %{id: id, source: source} = state) do
    :ok = EventSource.subscribe(source, partition: id)
    {:noreply, schedule_next_tick(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    %{systems: systems, events: events} = state

    systems
    |> Enum.flat_map(&expand_with_events(&1, events))
    |> batch_and_execute(state)

    new_state = %{state | events: []}
    {:noreply, schedule_next_tick(new_state)}
  end

  @impl true
  def handle_cast({:events, new_events}, %{events: events} = state) do
    {:noreply, %{state | events: events ++ new_events}}
  end

  ## Internal use ONLY

  @doc false
  def expand_with_events(system, events) do
    case system.__event_subscriptions__() do
      nil ->
        [system]

      subs ->
        events
        |> Enum.filter(&(&1.__struct__ in subs))
        |> Enum.map(&{system, &1})
    end
  end

  ## Private functions

  defp now(), do: System.monotonic_time(:millisecond)

  defp schedule_next_tick(state) do
    %{prev_tick: prev_tick, interval: interval} = state
    time = now()

    remaining_time =
      case interval do
        :infinity -> 0
        _ -> prev_tick + interval - time
      end

    # Sleep until next tick
    case remaining_time > 0 do
      true -> Process.send_after(self(), :tick, remaining_time)
      false -> send(self(), :tick)
    end

    %{state | prev_tick: time + remaining_time}
  end

  defp batch_and_execute([], _state), do: :ok

  defp batch_and_execute(systems, state) do
    %{concurrency: concurrency, system_timeout: system_timeout, prev_tick: prev_tick} = state

    {batch, remaining} = batch_systems(systems, concurrency)

    succeed =
      batch
      |> Task.async_stream(
        &execute(&1, prev_tick),
        max_concurrency: concurrency,
        ordered: false,
        timeout: system_timeout,
        on_timeout: :kill_task
      )
      |> Stream.filter(&match?({:ok, _}, &1))
      |> Enum.to_list()
      |> Enum.map(&elem(&1, 1))

    failed = Enum.reject(batch, &(&1 in succeed))

    if failed != [] do
      Logger.error(fn ->
        "#{length(failed)} systems killed/crashed: #{inspect(batch, limit: :infinity)}"
      end)
    end

    batch_and_execute(remaining, state)
  end

  # System subscribing to events
  defp execute({system, event} = value, prev_tick) do
    delta = now() - prev_tick
    system.run(event, delta)
    value
  catch
    kind, payload ->
      exception = Exception.format(kind, payload, __STACKTRACE__)
      Logger.error("#{inspect(value)} system crashed with error:\n#{exception}")
      :error
  end

  # Permanents systems
  defp execute(system, prev_tick) do
    delta = now() - prev_tick
    system.run(delta)
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
    case batch(system, components) do
      :sync ->
        batch_systems(remaining, 0, [value | acc], next, components)

      :next ->
        batch_systems(remaining, counter, acc, [value | next], components)

      {:ok, new_components} ->
        components = MapSet.union(components, MapSet.new(new_components))
        batch_systems(remaining, counter - 1, [value | acc], next, components)
    end
  end

  defp batch_systems([system | remaining], counter, acc, next, components) do
    case batch(system, components) do
      :sync ->
        batch_systems(remaining, 0, [system | acc], next, components)

      :next ->
        batch_systems(remaining, counter, acc, [system | next], components)

      {:ok, new_components} ->
        components = MapSet.union(components, MapSet.new(new_components))
        batch_systems(remaining, counter - 1, [system | acc], next, components)
    end
  end

  defp batch(system, components) do
    case {system.__lock_components__(), MapSet.size(components)} do
      {:sync, 0} ->
        :sync

      {:sync, _} ->
        :next

      {lock_components, _} ->
        not_member = Enum.map(lock_components, &(not MapSet.member?(components, &1)))
        if Enum.all?(not_member), do: {:ok, lock_components}, else: :next
    end
  end
end