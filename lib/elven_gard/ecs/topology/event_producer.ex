defmodule ElvenGard.ECS.Topology.EventProducer do
  @moduledoc """
  TODO: ElvenGard.ECS.Topology.EventProducer
  """

  use GenStage

  require Logger

  ## Public API

  @spec start_link(any) :: GenServer.on_start()
  def start_link(_opts) do
    if :global.whereis_name(__MODULE__) == :undefined do
      GenStage.start_link(__MODULE__, nil, name: {:global, __MODULE__})
    else
      :ignore
    end
  end

  ## GenStage behaviour

  @impl true
  def init(_) do
    {:producer, %{}}
  end

  @impl true
  def handle_demand(demand, state) when demand > 0 do
    IO.inspect(demand, label: "===> Demand")
    {:noreply, [], state}
  end
end
