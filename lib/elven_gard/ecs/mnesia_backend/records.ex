defmodule ElvenGard.ECS.MnesiaBackend.Records do
  @moduledoc false

  import Record, only: [defrecord: 3]

  alias ElvenGard.ECS.{Component, Entity}

  defrecord :entity, Entity, id: nil, parent_id: nil, partition: :default
  defrecord :component, Component, composite_key: nil, owner_id: nil, type: nil, component: nil

  @type entity ::
          record(:entity,
            id: Entity.t(),
            parent_id: Entity.id(),
            partition: Entity.partition()
          )

  @type component ::
          record(:component,
            composite_key: {owner_id :: Entity.id(), type :: Component.type()},
            owner_id: Entity.id(),
            type: Component.type(),
            component: Component.t()
          )
end
