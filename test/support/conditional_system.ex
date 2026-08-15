defmodule ElvenGard.ECS.ConditionalSystem do
  @moduledoc false

  use ElvenGard.ECS.System,
    lock_components: :sync,
    run_if: ElvenGard.ECS.HasChangesCondition

  ## ElvenGard.ECS.System callbacks

  @impl true
  def run(%{partition: test_pid, phase: phase}) do
    send(test_pid, {:conditional_system_ran, phase})
  end
end
