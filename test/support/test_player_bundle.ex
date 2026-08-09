defmodule ElvenGard.ECS.TestPlayerBundle do
  @moduledoc false

  use ElvenGard.ECS.Bundle,
    components: [
      player: ElvenGard.ECS.Components.PlayerComponent,
      position: ElvenGard.ECS.Components.PositionComponent,
      buff: ElvenGard.ECS.Components.BuffComponent
    ]

  alias ElvenGard.ECS.Entity

  ## ElvenGard.ECS.Bundle callbacks

  @impl true
  def new(attrs), do: Entity.entity_spec(attrs)
end
