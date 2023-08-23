defmodule ElvenGard.ECS.Config do
  @moduledoc false

  def backend(), do: Application.get_env(:elvengard_ecs, :backend, ElvenGard.ECS.ETSBackend)
end
