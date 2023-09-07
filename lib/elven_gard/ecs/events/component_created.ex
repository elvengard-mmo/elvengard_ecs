defmodule ElvenGard.ECS.Events.ComponentCreated do
  @moduledoc """
  Special framework event triggered automatically when a new component is created.

  Contains the component state struct and it's entity.
  """
  use ElvenGard.ECS.Event, fields: [:entity, :component]

  alias ElvenGard.ECS.{Component, Entity}

  @type t :: %__MODULE__{entity: Entity.t(), component: Component.t()}
end
