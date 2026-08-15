defmodule ElvenGard.ECS.MnesiaBackend.Records do
  @moduledoc false

  import Record, only: [defrecord: 3]

  alias ElvenGard.ECS.{Component, Entity}
  alias ElvenGard.ECS.MnesiaBackend.{ComponentRevision, Revision}

  defrecord :entity, Entity, id: nil, parent_id: nil, partition: :default

  defrecord :component, Component, composite_key: nil, owner_id: nil, type: nil, component: nil

  defrecord :revision, Revision, partition: nil, revision: 0

  defrecord :component_revision, ComponentRevision,
    composite_key: nil,
    scope: nil,
    owner_id: nil,
    revision: 0

  @type entity ::
          record(:entity,
            id: Entity.id(),
            parent_id: Entity.id() | nil,
            partition: Entity.partition()
          )

  @type component ::
          record(:component,
            composite_key: {owner_id :: Entity.id(), type :: Component.type()},
            owner_id: Entity.id(),
            type: Component.type(),
            component: Component.t()
          )

  @type revision ::
          record(:revision,
            partition: Entity.partition(),
            revision: non_neg_integer()
          )

  @type component_revision ::
          record(:component_revision,
            composite_key: {Entity.partition(), Component.type(), Entity.id()},
            scope: {Entity.partition(), Component.type()},
            owner_id: Entity.id(),
            revision: non_neg_integer()
          )
end
