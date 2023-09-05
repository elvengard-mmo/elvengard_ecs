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

    state = %{
      id: id,
      prev_tick: now(),
      interval: interval,
      systems: systems,
      concurrency: concurrency,
      source: source,
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

    IO.inspect("tick")

    systems
    |> Enum.flat_map(&expand_with_events(&1, events))
    |> IO.inspect()

    new_state = %{state | events: []}
    {:noreply, schedule_next_tick(new_state)}
  end

  @impl true
  def handle_cast({:events, new_events}, %{events: events} = state) do
    {:noreply, %{state | events: events ++ new_events}}
  end

  ## Internal use ONLY

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
end
