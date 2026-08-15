# Queries

`ElvenGard.ECS.Query` provides direct lookups and composable selection queries.
All reads are delegated to the configured backend.

## Direct lookups

```elixir
alias ElvenGard.ECS.Query

{:ok, entity} = Query.fetch_entity(entity_id)
{:ok, partition} = Query.partition(entity)
{:ok, parent} = Query.parent(entity)
{:ok, children} = Query.children(entity)
{:ok, components} = Query.list_components(entity)
```

`Query.parent/1` returns `{:ok, nil}` for a root entity. Parent and child checks
refer to direct relationships, not all ancestors or descendants:

```elixir
Query.parent_of?(parent, child)
Query.child_of?(child, parent)
```

## Selecting entities

Build a query with `Query.select/2` and execute it with `Query.all/1`:

```elixir
alias ElvenGard.ECS.{Entity, Query}
alias MyGame.Components.{Player, Position}

query =
  Query.select(Entity,
    with: [Player],
    preload: [Position],
    partition: :world_1
  )

results = Query.all(query)
```

Selecting `Entity` returns `{entity, components}` pairs. Components listed in
`:with` are mandatory and are included in the component list. Components listed
only in `:preload` are optional.

Use `preload: :all` to return every component owned by each matching entity.

## Filtering component fields

A mandatory component can include backend match filters:

```elixir
query =
  Query.select(Entity,
    with: [
      {Player, [{:==, :name, "Ada"}]}
    ]
  )
```

Each filter is `{operator, field, value}`. Operators are passed to the default
Mnesia backend as match-spec guard operators. Multiple filters on one component
are combined with logical `and`.

Use `:in` to match one field against several exact values in one query. This is
useful for area-of-interest queries over a set of visible chunks:

```elixir
visible_chunks = [{10, 10}, {10, 11}, {11, 10}]

query =
  Query.select(Entity,
    with: [{Position, [{:in, :chunk, visible_chunks}]}],
    partition: room_id
  )
```

An empty membership list matches nothing.

Tuple constants, including references and composite identifiers, are escaped
for Mnesia match specs automatically.

## Restricting reads with candidate sources

Field filters are evaluated after the backend finds entities. Use a candidate
source when a secondary index can identify a smaller entity set before their
components are loaded:

```elixir
source = MyGame.SpatialIndex.circle(room_id, {100, 200}, 500)

query =
  Query.select({Entity, Player, Position},
    with: :selected,
    partition: room_id,
    source: source
  )

nearby_players = Query.all(query)
```

The source struct implements `ElvenGard.ECS.Query.Source` and returns entity
IDs for the requested partition. Query filters remain authoritative: candidate
IDs that do not contain every mandatory component or fail a field filter are
discarded normally.

Sources are resolved when `Query.all/1` or `Query.one/1` executes. Duplicate
IDs are removed before the backend loads components. A source must only return
live IDs belonging to the partition it receives.

## Changed components and membership caches

Capture a bounded partition cursor, then select only the existing entities
whose selected component modules were written after it:

```elixir
cursor = Query.cursor(room_id)

changed_players =
  {Entity, Position, Movement}
  |> Query.select(
    with: :selected,
    partition: room_id,
    changed: [Position, Movement],
    since: cursor
  )
  |> Query.all()
```

The default Mnesia backend retains only the current revision for each
entity/component pair. A cursor therefore has bounded storage: it is suitable
for incremental systems, but it is not an event log. Use the transaction's
`ElvenGard.ECS.ChangeSet` when a system must observe deletions.

For stable sparse queries, `cache: true` starts candidate selection from the
first mandatory component's membership index:

```elixir
projectiles =
  {Entity, Projectile, Position}
  |> Query.select(with: :selected, partition: room_id, cache: true)
  |> Query.all()
```

The cache is opt-in because scanning a dense component membership can cost
more than starting from the partition's entity index. A membership cache seeds
only the first mandatory component from authoritative ECS data, then maintains
that bounded membership transactionally. Writes to unrelated component modules
do not increment a revision or update the cached membership. A change cursor
separately enables revision tracking for every component module in its
partition. Capture the first cursor or execute the first cached query before
entering a command transaction; once initialized, both query modes remain
available inside transactions.

## Selecting components

Use a component module as the return type to receive component structs rather
than entities:

```elixir
query = Query.select(Position, partition: :world_1)
positions = Query.all(query)
```

The return component is automatically mandatory.

## Tuple results

A tuple return type builds one tuple per matching entity:

```elixir
query = Query.select({Entity, Player, Position}, with: [Player])
results = Query.all(query)
```

Modules named in the tuple are loaded automatically. Components not listed in
`:with` remain optional and appear as `nil` when absent.

Pass `with: :selected` when every component named in the tuple must exist:

```elixir
query = Query.select({Entity, Player, Position}, with: :selected)
```

This is a shorthand for `with: [Player, Position]`; `Entity` is ignored when
building the mandatory component list.

## Materializing bundles

A tuple query containing `Entity` can be materialized into a bundle declared
with `ElvenGard.ECS.Bundle`:

```elixir
defmodule MyGame.PlayerBundle do
  use ElvenGard.ECS.Bundle,
    components: [
      player: MyGame.Components.Player,
      position: MyGame.Components.Position,
      health: MyGame.Components.Health
    ]

  @impl true
  def new(attrs), do: ElvenGard.ECS.Entity.entity_spec(attrs)
end

bundles = Query.all(query, into: MyGame.PlayerBundle)
bundle = Query.one(query, into: MyGame.PlayerBundle)
```

Selected components populate their fields. Unselected fields contain
`:not_loaded`, while a selected component that does not exist contains `nil`.
Generated getters return the component, return `nil` for an absent component,
and raise `ElvenGard.ECS.Bundle.NotLoadedError` for an unloaded field:

```elixir
position = MyGame.PlayerBundle.position(bundle)
{:error, :not_loaded} = MyGame.PlayerBundle.fetch_health(bundle)
```

Preloading returns a new bundle and skips fields that were already loaded:

```elixir
bundle = MyGame.PlayerBundle.preload(bundle, [:position, :health])
bundle = MyGame.PlayerBundle.preload(bundle, :position, force: true)
```

Use `force: true` to refresh a loaded component or recheck a previously absent
component. Bundles require `Entity` in the tuple because later preloads need the
component owner.

## Expecting one result

`Query.one/1` returns `nil` for no match and the value itself for exactly one
match:

```elixir
case Query.one(Query.select(Player, with: [{Player, [{:==, :name, "Ada"}]}])) do
  nil -> :not_found
  player -> {:ok, player}
end
```

It raises when the query returns more than one value. Use `Query.all/1` when
multiple matches are expected.

## Indexed entity selections

The default backend also provides direct indexed selections:

```elixir
{:ok, children} = Query.select_entities(with_parent: parent)
{:ok, others} = Query.select_entities(without_parent: parent)
{:ok, entities} = Query.select_entities(with_component: Player)
```

Each call accepts one criterion.
