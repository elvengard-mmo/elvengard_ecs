defmodule ElvenGard.ECS.Events.EntitySpawned do
  @moduledoc """
  Special framework event triggered automatically when a new entity is spawned.

  Contains the entity struct and his specs.
  """
  use ElvenGard.ECS.Event, fields: [:entity, :components, :children, :parent]

  alias ElvenGard.ECS.{Component, Entity}

  @type t :: %__MODULE__{
          entity: Entity.t(),
          components: [Component.spec()],
          children: [Entity.t()],
          parent: Entity.t() | nil
        }
end
