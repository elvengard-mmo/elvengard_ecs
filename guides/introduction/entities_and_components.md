# Entities and Components

ElvenGard.ECS separates identity from data. An entity is a lightweight ID;
components hold game state and are stored separately by the backend.

## Entities

`ElvenGard.ECS.Entity` contains only an `:id` field:

```elixir
%ElvenGard.ECS.Entity{id: "player-42"}
```

Use `ElvenGard.ECS.Entity.entity_spec/1` rather than constructing the creation
map manually. It supplies defaults for every field required by
`ElvenGard.ECS.Command.spawn_entity/1`:

```elixir
spec =
  ElvenGard.ECS.Entity.entity_spec(
    id: "player-42",
    components: [],
    children: [],
    parent: nil,
    partition: :default
  )
```

When `:id` is omitted, a UUID v4 string is generated.

## Component definitions

A component is a regular struct:

```elixir
defmodule MyGame.Health do
  use ElvenGard.ECS.Component,
    state: [current: 100, maximum: 100]
end
```

Component specifications have three accepted forms:

```elixir
# Use every default.
MyGame.Health

# Override selected defaults.
{MyGame.Health, current: 75}

# Use an already constructed component.
%MyGame.Health{current: 25, maximum: 120}
```

All three forms are accepted in an entity specification and by
`ElvenGard.ECS.Command.add_component/2`.

## Adding and reading components

```elixir
alias ElvenGard.ECS.{Command, Query}

{:ok, health} = Command.add_component(entity, {MyGame.Health, current: 80})
{:ok, [^health]} = Query.fetch_components(entity, MyGame.Health)
{:ok, ^health} = Query.fetch_component(entity, MyGame.Health)
```

An entity may own multiple distinct components of the same module. In that
case, use `Query.fetch_components/2`; `Query.fetch_component/2` raises because
the result is ambiguous.

## Updating components

Pass a module when the entity must own exactly one component of that module:

```elixir
{:ok, health} = Command.update_component(entity, MyGame.Health, current: 60)
```

Pass a component struct to select one exact value when duplicates are valid:

```elixir
{:ok, updated} = Command.update_component(entity, health, current: 50)
```

A module selector returns `{:error, :multiple_values}` when multiple values
exist and `{:error, :not_found}` when none exists.

## Replacing and deleting components

`ElvenGard.ECS.Command.replace_component/2` removes every component of the same
module and stores the supplied value:

```elixir
:ok = Command.replace_component(entity, %MyGame.Health{current: 100, maximum: 150})
```

Deletion follows the same distinction:

```elixir
# Delete every Health component.
:ok = Command.delete_component(entity, MyGame.Health)

# Delete only values equal to this struct.
:ok = Command.delete_component(entity, %MyGame.Health{current: 10, maximum: 100})
```

Component lookups intentionally avoid a separate entity-existence read. An
unknown entity and an entity without matching components therefore both return
an empty list from `Query.list_components/1` or `Query.fetch_components/2`.

