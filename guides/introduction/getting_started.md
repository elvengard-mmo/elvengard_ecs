# Getting Started

This guide introduces ElvenGard.ECS by defining a component, creating an
entity, and reading it back.

## Add the dependency

Add ElvenGard.ECS to `mix.exs`:

```elixir
defp deps() do
  [
    {:elvengard_ecs, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies:

```console
mix deps.get
```

ElvenGard.ECS starts its default Mnesia backend with the application. The
backend creates and waits for its entity and component tables before the
application continues starting.

## Define components

Components are structs containing one aspect of game state:

```elixir
defmodule MyGame.Components.Player do
  use ElvenGard.ECS.Component,
    state: [name: nil, level: 1]
end

defmodule MyGame.Components.Position do
  use ElvenGard.ECS.Component,
    state: [map_id: nil, x: 0, y: 0]
end
```

The `:state` keyword list defines the struct fields and their defaults.

## Spawn an entity

Build a complete specification with `ElvenGard.ECS.Entity.entity_spec/1` and
pass it to `ElvenGard.ECS.Command.spawn_entity/1`:

```elixir
alias ElvenGard.ECS.{Command, Entity}
alias MyGame.Components.{Player, Position}

spec =
  Entity.entity_spec(
    components: [
      {Player, name: "Ada"},
      {Position, map_id: :capital, x: 10, y: 20}
    ],
    partition: :world_1
  )

{:ok, {entity, components}} = Command.spawn_entity(spec)
```

The operation creates the entity, attaches its relationships, and inserts its
components in one transaction.

## Read the entity

Use `ElvenGard.ECS.Query` for reads:

```elixir
alias ElvenGard.ECS.Query

{:ok, ^entity} = Query.fetch_entity(entity.id)
{:ok, :world_1} = Query.partition(entity)
{:ok, components} = Query.list_components(entity)
```

Selection queries can return entities together with selected components:

```elixir
query = Query.select(Entity, with: [Player], preload: [Position])
results = Query.all(query)
```

## Next steps

Continue with:

  * [Entities and Components](entities_and_components.html)
  * [Queries](queries.html)
  * [Transactions and Relationships](transactions_and_relationships.html)
  * [Events and Systems](events_and_systems.html)

