defmodule ElvenGard.ECS.Application do
  @moduledoc false

  use Application

  alias ElvenGard.ECS.Config

  @impl true
  def start(_type, _args) do
    children = [
      # FIXME: Hadcoded for now
      {ElvenGard.ECS.MnesiaBackend.ClusterManager, [retry: true]},
      {Config.backend(), []}
    ]

    opts = [strategy: :one_for_one, name: ElvenGard.ECS.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
