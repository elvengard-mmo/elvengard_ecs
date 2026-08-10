defmodule ElvenGard.ECS.PhaseRecordingSystem do
  @moduledoc false

  use ElvenGard.ECS.System, lock_components: :sync

  ## ElvenGard.ECS.System callbacks

  @impl true
  def run(%{partition: test_pid, phase: phase}) do
    send(test_pid, {:phase_run, phase})
  end
end
