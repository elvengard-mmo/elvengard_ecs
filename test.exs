Code.require_file("lib/elven_gard/ecs/topology/cluster_dispatcher.ex", __DIR__)

## Setup

Mix.install([{:gen_stage, "~> 1.2"}])
Logger.configure(level: :error)

## Code

defmodule EventProducer do
  use GenStage

  ## Public API

  @spec start_link(any) :: GenServer.on_start()
  def start_link(_opts) do
    GenStage.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @spec push(any) :: :ok
  def push(events) do
    GenServer.cast(__MODULE__, {:push, List.wrap(events)})
  end

  ## GenStage behaviour

  @impl true
  def init(_) do
    dispatcher = {ElvenGard.ECS.Topology.ClusterDispatcher, key: &{&1, Map.get(&1, :cluster, :default)}}
    {:producer, %{}, dispatcher: dispatcher}
  end

  @impl true
  def handle_demand(demand, state) when demand > 0 do
    # IO.inspect(demand, label: "===> Demand")
    {:noreply, [], state}
  end

  @impl true
  def handle_cast({:push, events}, state) do
    {:noreply, events, state}
  end
end

defmodule Consumer do
  use GenStage

  def start_link(cluster) do
    GenStage.start_link(__MODULE__, cluster)
  end

  def init(cluster) do
    IO.puts("Consumer #{cluster} started")
    {:consumer, %{cluster: cluster}}
  end

  def handle_events(events, _from, %{cluster: cluster} = state) do
    color = case cluster do
      1 -> IO.ANSI.blue()
      2 -> IO.ANSI.green()
      3 -> IO.ANSI.yellow()
    end

    # Inspect the event.
    time = to_string(DateTime.utc_now()) |> String.split(".") |> Enum.at(0)
    IO.puts("#{color}[#{time}] Consumer##{cluster}: #{inspect(events)}#{IO.ANSI.reset()}")

    # Wait for a second.
    Process.sleep(cluster * 1000)

    # We are a consumer, so we would never emit items.
    {:noreply, [], state}
  end
end

{:ok, a} = EventProducer.start_link(nil)
{:ok, b} = Consumer.start_link(1)
{:ok, c} = Consumer.start_link(2)
{:ok, d} = Consumer.start_link(3)


GenStage.sync_subscribe(b, to: a, max_demand: 1, min_demand: 0, cluster: "map_1")
Process.sleep(1000)

# Push some events
1..20
|> Enum.zip(Stream.cycle(["map_2", "map_3", "map_4", "map_1"]))
|> Enum.map(&%{cluster: elem(&1, 1), value: elem(&1, 0)})
|> EventProducer.push()

Process.sleep(2000)

GenStage.sync_subscribe(c, to: a, max_demand: 1, min_demand: 0, cluster: "map_2")
GenStage.sync_subscribe(d, to: a, max_demand: 1, min_demand: 0, cluster: "map_3")

Process.sleep(2000000)
