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

## Named command batches

Use `ElvenGard.ECS.Multi` when a transaction contains several named commands or
when later commands depend on earlier results:

```elixir
alias ElvenGard.ECS.{Command, Multi}

multi =
  Multi.new()
  |> Multi.spawn_entity(:player, player_spec)
  |> Multi.add_component(
    :spawn_protection,
    fn %{player: {entity, _components}} -> entity end,
    MyGame.SpawnProtection
  )
  |> Multi.run(:notify_domain, fn %{player: {entity, _components}} ->
    MyGame.record_spawn(entity)
  end)

case Command.transact(multi) do
  {:ok, %{player: {entity, components}}} ->
    {:ok, entity, components}

  {:error, failed_operation, reason, changes_so_far} ->
    {:error, failed_operation, reason, changes_so_far}
end
```

Every name must be unique. `Multi.append/2` and `Multi.prepend/2` combine static
batches, while `Multi.merge/2` builds a dependent batch from results produced
so far. The first `{:error, reason}` rolls every ECS write back. A `run/3`
callback must not perform an irreversible external side effect because the
backend cannot roll that effect back.

Replication systems can request the committed mutations alongside the named
results:

```elixir
{:ok, results, change_set} = Command.transact_with_changes(multi)
changes = ElvenGard.ECS.ChangeSet.to_list(change_set)
```

The change set contains only declared ECS commands from this transaction.
`run/3` and `put/3` are excluded. It is returned as an ordinary immutable value
and is never retained by the ECS, so later ticks cannot grow an implicit
history.

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
