# Transactions and Relationships

`ElvenGard.ECS.Command` is the write API. Compound entity operations are
transactional, and callers can group additional writes explicitly.

## Explicit transactions

`ElvenGard.ECS.Command.transaction/1` returns `{:ok, result}` when its callback
completes:

```elixir
alias ElvenGard.ECS.Command

{:ok, updated_component} =
  Command.transaction(fn ->
    {:ok, component} = Command.add_component(entity, MyGame.Health)
    component
  end)
```

Abort the current transaction when a domain condition fails:

```elixir
Command.transaction(fn ->
  case allowed?(entity) do
    true -> perform_changes(entity)
    false -> Command.abort(:not_allowed)
  end
end)
```

The aborted transaction returns `{:error, :not_allowed}` and rolls back its
writes.

## Spawning entities atomically

`Command.spawn_entity/1` creates the entity, attaches its children, and inserts
its components in one transaction:

```elixir
alias ElvenGard.ECS.Entity

spec =
  Entity.entity_spec(
    parent: parent,
    children: existing_children,
    components: [MyGame.Health],
    partition: :world_1
  )

{:ok, {entity, components}} = Command.spawn_entity(spec)
```

Duplicate IDs and cyclic relationships abort the complete operation.

## Parent and child relationships

Relationships are direct and single-parent:

```elixir
:ok = Command.set_parent(child, parent)
:ok = Command.set_parent(child, nil)
```

The backend walks the complete parent chain before accepting an update. Direct
cycles and longer cycles such as `A -> B -> C -> A` return
`{:error, :cyclic_relationship}`.

Partitions are independent from relationships:

```elixir
:ok = Command.set_partition(entity, :world_2)
```

Moving a parent does not automatically move its descendants.

## Despawning and cascades

By default, despawning an entity recursively deletes all descendants and their
components:

```elixir
{:ok, {deleted_entity, deleted_components}} = Command.despawn_entity(entity)
```

Supply a callback to choose whether each child subtree is deleted:

```elixir
on_child_delete = fn child, _components ->
  case persistent?(child) do
    true ->
      :ok = Command.set_parent(child, nil)
      :ignore

    false ->
      :delete
  end
end

Command.despawn_entity(entity, on_child_delete)
```

Returning `:ignore` keeps the child and its descendants. It does not rewrite
the child's parent automatically, so reparent a retained child when the
application requires a valid parent reference.

The complete recursive cascade shares one transaction. A callback crash, an
explicit abort, or another backend failure rolls back every deletion.

