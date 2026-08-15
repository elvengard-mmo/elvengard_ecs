defmodule ElvenGard.ECS.OnDemandSchedulingSystem do
  @moduledoc false

  use ElvenGard.ECS.System, lock_components: :sync

  alias ElvenGard.ECS.System, as: ECSSystem

  ## ElvenGard.ECS.System callbacks

  @impl true
  def run(%{partition: {test_pid, counter}}) do
    count = :atomics.add_get(counter, 1, 1)
    send(test_pid, {:on_demand_tick, count})

    case count do
      1 -> ECSSystem.schedule_after(5)
      2 -> :ok
    end
  end
end
