defmodule ElvenGard.ECS.Events.EntityDespawned do
  @moduledoc """
  Special framework event triggered automatically when a new entity is despawned.

  Contains the entity struct.
  """
  use ElvenGard.ECS.Event, fields: [:entity]

  alias ElvenGard.ECS.Entity

  @type t :: %__MODULE__{entity: Entity.t()}
end
