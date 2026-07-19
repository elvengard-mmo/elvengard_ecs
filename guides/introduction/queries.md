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

Tuple constants, including references and composite identifiers, are escaped
for Mnesia match specs automatically.

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

