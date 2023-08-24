defmodule ElvenGard.ECS.MnesiaBackend.Records do
  @moduledoc false

  import Record, only: [defrecord: 3]

  alias ElvenGard.ECS.{Component, Entity}

  defrecord :entity, Entity, id: nil, parent_id: nil
  defrecord :component, Component, type: nil, owner_id: nil, component: nil

  @type entity :: record(:entity, id: Entity.t(), parent_id: Entity.id())
  @type component ::
          record(:component,
            type: Component.type(),
            owner_id: Entity.id(),
            component: Component.t()
          )
end
