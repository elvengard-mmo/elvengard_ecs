defmodule ElvenGard.ECS.Events.ComponentDeleted do
  @moduledoc """
  Special framework event triggered automatically when a new component is deleted.

  Contains the component state struct and it's entity.
  """
  use ElvenGard.ECS.Event, fields: [:entity, :component]

  alias ElvenGard.ECS.{Component, Entity}

  @type t :: %__MODULE__{entity: Entity.t(), component: Component.t()}
end