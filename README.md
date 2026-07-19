# ElvenGard.ECS

<!-- MDOC !-->

[![Hex.pm version](https://img.shields.io/hexpm/v/elvengard_ecs.svg?style=flat)](https://hex.pm/packages/elvengard_ecs)
[![Hex.pm license](https://img.shields.io/hexpm/l/elvengard_ecs.svg?style=flat)](https://hex.pm/packages/elvengard_ecs)
[![Build Status](https://github.com/ImNotAVirus/elvengard_ecs/actions/workflows/elixir.yml/badge.svg?branch=main)](https://github.com/ImNotAVirus/elvengard_ecs/actions/workflows/elixir.yml)
[![Coverage Status](https://coveralls.io/repos/github/ImNotAVirus/elvengard_ecs/badge.svg?branch=main)](https://coveralls.io/github/ImNotAVirus/elvengard_ecs?branch=main)

## What is ElvenGard

ElvenGard is a modular toolkit for building multiplayer game servers in Elixir.
It provides reusable foundations for concerns shared by online games, including
networking, world state, entities, movement, quests, and instances. Each library
can be adopted independently so a game can keep its own domain model and
architecture.

## What is ElvenGard.ECS

[ElvenGard.ECS](https://github.com/ImNotAVirus/elvengard_ecs) is an
Entity-Component-System toolkit for stateful multiplayer game servers. It
provides:

1. **Entities and Components:** model game objects as lightweight identities
   with independently stored component structs.
2. **Transactional Commands:** create, update, relate, and delete game state
   through atomic operations backed by Mnesia.
3. **Composable Queries:** select entities or components by component presence,
   field filters, partition, and return shape.
4. **Partitioned Systems:** execute tick-based and event-driven systems in
   conflict-aware concurrent batches.
5. **Event Routing:** route events to logical partitions, buffer events before
   subscribers start, and expose telemetry for system execution.

The default backend is Mnesia. Applications supervise their own event source
and partitions, which keeps the topology explicit and allows each game to
choose its world layout and tick rates.

## Installation

The package can be installed by adding `elvengard_ecs` to your list of dependencies in `mix.exs`:

```elixir
def deps() do
  [
    {:elvengard_ecs, "~> 0.1.0"}
  ]
end
```

The docs can be found at [https://hexdocs.pm/elvengard_ecs](https://hexdocs.pm/elvengard_ecs).

## Quick start

Define a component:

```elixir
defmodule MyGame.Position do
  use ElvenGard.ECS.Component,
    state: [map_id: nil, x: 0, y: 0]
end
```

Create and query an entity:

```elixir
alias ElvenGard.ECS.{Command, Entity, Query}

spec =
  Entity.entity_spec(
    components: [{MyGame.Position, map_id: :capital, x: 10, y: 20}],
    partition: :world_1
  )

{:ok, {entity, [%MyGame.Position{}]}} = Command.spawn_entity(spec)
{:ok, [%MyGame.Position{x: 10, y: 20}]} = Query.fetch_components(entity, MyGame.Position)
```

## Guides

  * [Getting Started](guides/introduction/getting_started.md)
  * [Entities and Components](guides/introduction/entities_and_components.md)
  * [Queries](guides/introduction/queries.md)
  * [Transactions and Relationships](guides/introduction/transactions_and_relationships.md)
  * [Events and Systems](guides/introduction/events_and_systems.md)

**/!\ This toolkit is currently not production ready !**

## Projects using ElvenGard

- [AvantHeim](https://github.com/ImNotAVirus/AvantHeim): Created by the same developer as ElvenGard, this is a [NosTale](https://gameforge.com/en-US/play/nostale) server emulator

## Contributing

I'm currently developing this project. Any review or PR is welcome.
Also, feel free to fork the repository and contribute.
