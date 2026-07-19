# Events and Systems

The topology layer routes events to partitions and executes systems in
conflict-aware concurrent batches.

## Define an event

```elixir
defmodule MyGame.Events.MoveRequested do
  use ElvenGard.ECS.Event,
    fields: [entity: nil, dx: 0, dy: 0]
end
```

Every event also contains `:partition`, which defaults to `:default`, and
`:inserted_at`, which is populated by `ElvenGard.ECS.push/2`.

## Define a system

```elixir
defmodule MyGame.Systems.Movement do
  use ElvenGard.ECS.System,
    lock_components: [MyGame.Components.Position],
    event_subscriptions: [MyGame.Events.MoveRequested]

  @impl true
  def run(%MyGame.Events.MoveRequested{} = event, context) do
    # Read and update the entity in context.partition.
    {event, context}
  end
end
```

Implement `run/2` for subscribed events and `run/1` for work that must run on
every tick. A system may implement both callbacks.

The callback context contains:

```elixir
%{partition: partition_id, delta: elapsed_milliseconds}
```

Startup systems receive `delta: :startup`.

## Component locks and concurrency

The required `:lock_components` option declares scheduling conflicts:

  * systems whose lock lists overlap are placed in different batches;
  * systems with disjoint lock lists may run concurrently;
  * `lock_components: :sync` runs the system in an isolated batch;
  * `lock_components: []` declares no component conflict.

These locks only control system scheduling. They do not open an ECS transaction
and do not replace the locking performed by the storage backend.

## Define a partition

```elixir
defmodule MyGame.WorldPartition do
  use ElvenGard.ECS.Topology.Partition

  @impl true
  def setup(opts) do
    id = Keyword.fetch!(opts, :id)

    {id,
     systems: [MyGame.Systems.Movement],
     startup_systems: [MyGame.Systems.LoadWorld],
     interval: Keyword.get(opts, :interval, 50),
     concurrency: Keyword.get(opts, :concurrency, System.schedulers_online())}
  end
end
```

The `:systems` option is required. Other options are:

  * `:startup_systems` - systems run once before event subscription;
  * `:interval` - milliseconds between scheduled ticks; use `0` to run without
    an intentional delay;
  * `:concurrency` - maximum systems running in one batch;
  * `:event_source` - source name or PID;
  * `:system_timeout` - execution timeout, defaulting to `:infinity`.

A regular system crash or timeout is logged and does not prevent later batches
from running. A startup-system failure stops partition startup.

## Supervise the topology

The ECS application starts the storage backend, while the host application
supervises its event source and partitions:

```elixir
def start(_type, _args) do
  children = [
    ElvenGard.ECS.Topology.EventSource,
    {MyGame.WorldPartition, id: :world_1},
    {MyGame.WorldPartition, id: :world_2}
  ]

  Supervisor.start_link(children, strategy: :one_for_one)
end
```

The default event source has a global name. One process may subscribe to each
partition identifier. A custom local source can be started with `name: name`
and passed to partitions as `event_source: name`.

Use `ElvenGard.ECS.Topology.wait_for_partitions/2` when another process must
wait for partition startup to complete.

## Dispatch events

```elixir
event = %MyGame.Events.MoveRequested{
  entity: entity,
  dx: 1,
  dy: 0,
  partition: :world_1
}

{:ok, [dispatched_event]} = ElvenGard.ECS.push(event)
```

Pass `partition: id` to `push/2` to override the destination on every event in
the call.

Events for a partition without a subscriber are buffered in order. The event
source retains the latest 10,000 buffered events per partition and logs a
warning when older events are dropped.

## Telemetry

Partitions emit these telemetry events:

  * `[:elvengard_ecs, :startup_system_run, :start | :stop | :exception]`
  * `[:elvengard_ecs, :system_run, :start | :stop | :exception]`
  * `[:elvengard_ecs, :partition_init]`

System metadata includes the partition and system module. Event-driven runs
also include the event. The partition initialization event reports its duration
and startup metadata.

