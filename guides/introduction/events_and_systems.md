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
%{
  partition: partition_id,
  delta: elapsed_milliseconds,
  phase: :tick,
  change_sets: previously_committed_change_sets,
  outputs: previously_emitted_system_outputs
}
```

The phase is one of `:startup`, `:pre_tick`, `:tick`, `:post_tick`, or
`:shutdown`. Startup systems receive `delta: :startup`.

## Conditional and on-demand systems

Use a condition module when a frame system only has work for some ticks. The
module implements `run?/1` and receives the same bounded tick context that the
system will receive:

```elixir
defmodule MyGame.HasChanges do
  def run?(%{change_sets: change_sets}), do: change_sets != []
end

defmodule MyGame.ReplicationSystem do
  use ElvenGard.ECS.System,
    lock_components: :sync,
    run_if: MyGame.HasChanges
end
```

Partitions configured with `tick_mode: :on_demand` sleep until an event or an
explicit `ElvenGard.ECS.Topology.Partition.wake/1`. A system keeps temporal
simulation active by returning the earliest delay it needs:

```elixir
ElvenGard.ECS.System.schedule_after(33, result)
```

Scheduling wraps an existing result, including `emit_changes/1` and
`emit_changes/2`; committed changes and ephemeral outputs remain visible to
later systems. The partition retains only the earliest requested deadline and
does not persist a timer history.

## Propagate committed changes through one tick

A system can expose its committed transaction to later systems without keeping
a journal:

```elixir
alias ElvenGard.ECS.{Command, System}

{:ok, _results, change_set} = Command.transact_with_changes(multi)
System.emit_changes(change_set)
```

The partition adds non-empty emitted change sets to `context.change_sets` for
later execution batches and phases. Systems in the same concurrent batch see
the same input context; their results become visible after the batch barrier.
The list preserves configured execution order and is discarded after the
post-tick phase. Startup, shutdown, and the first pre-tick batch receive an
empty list.

This mechanism is intended for bounded derived work such as replication,
secondary-index synchronization, or audit telemetry for the current tick. It
does not persist change sets, replay them after a crash, or make them part of
authoritative ECS state.

## Reuse derived work later in the tick

A system can attach one ephemeral output to its committed changes:

```elixir
System.emit_changes(change_set, prepared_replication)
```

Later systems retrieve the latest output from that system without coupling to
the internal representation of `context.outputs`:

```elixir
case System.output(context, MyGame.Systems.Simulation) do
  {:ok, prepared_replication} -> replicate(prepared_replication)
  :error -> :ok
end
```

Outputs follow the same batch barriers and configured execution order as
change sets. They are discarded after post-tick and are never written to the
storage backend. Use them to avoid recomputing a bounded derived value during
the same tick, not as an authoritative resource or historical cache.

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
     pre_tick_systems: [MyGame.Systems.ApplyInput],
     systems: [MyGame.Systems.Movement],
     post_tick_systems: [MyGame.Systems.Replication],
     startup_systems: [MyGame.Systems.LoadWorld],
     shutdown_systems: [MyGame.Systems.UnloadWorld],
     interval: Keyword.get(opts, :interval, 50),
     concurrency: Keyword.get(opts, :concurrency, System.schedulers_online())}
  end
end
```

The `:systems` option is required. Other options are:

  * `:startup_systems` - systems run once before event subscription;
  * `:pre_tick_systems` - systems run before `:systems` on every tick;
  * `:post_tick_systems` - systems run after `:systems` on every tick;
  * `:shutdown_systems` - systems run sequentially when the partition stops
    gracefully;
  * `:interval` - milliseconds between scheduled ticks; use `0` to run without
    an intentional delay;
  * `:tick_mode` - `:continuous` or `:on_demand`;
  * `:initial_tick` - whether an on-demand partition runs once after startup;
  * `:concurrency` - maximum systems running in one batch;
  * `:event_source` - source name or PID;
  * `:system_timeout` - execution timeout, defaulting to `:infinity`.

A regular system crash or timeout is logged and does not prevent later batches
from running. A startup-system failure stops partition startup.

Every tick has strict phase barriers:

```text
pre_tick_systems -> systems -> post_tick_systems
```

Component locks and concurrency are evaluated independently inside each phase.

Shutdown systems receive the partition, the `:shutdown` lifecycle delta, and
the stop reason:

```elixir
defmodule MyGame.Systems.UnloadWorld do
  use ElvenGard.ECS.System, lock_components: :sync

  @impl true
  def run(%{partition: partition, delta: :shutdown, reason: reason}) do
    MyGame.delete_partition_entities(partition)
    {partition, reason}
  end
end
```

Each shutdown system is isolated: a failure is logged and the remaining
shutdown systems still run. Shutdown hooks are best-effort lifecycle hooks.
They run for graceful GenServer and supervisor shutdowns, but cannot run after
an untrappable `:kill` exit or a VM crash.

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
the call. This is the fire-and-forget path: it sends one asynchronous message
without creating a receipt or retaining waiter state.

Use `push_and_wait/2` when the caller must know that every destination
partition completed the tick containing the events:

```elixir
{:ok, [processed_event]} =
  ElvenGard.ECS.push_and_wait(event,
    partition: :world_1,
    timeout: 1_000
  )
```

The acknowledgement is emitted after the partition completes its pre-tick,
regular tick, and post-tick systems. It confirms ECS processing, not delivery
to an external client. Every destination partition must already be subscribed.
A timeout stops waiting but never cancels events already delivered to a
partition.

Events for a partition without a subscriber are buffered in order. The event
source retains the latest 10,000 buffered events per partition and logs a
warning when older events are dropped.

## Telemetry

Timed operations use `:telemetry.span/3`, so each prefix emits `:start`,
`:stop`, and `:exception` events. Durations use native time units.

The available span prefixes are:

  * `[:elvengard_ecs, :query]`
  * `[:elvengard_ecs, :multi]`
  * `[:elvengard_ecs, :event_dispatch]`
  * `[:elvengard_ecs, :partition_tick]`
  * `[:elvengard_ecs, :phase_run]`
  * `[:elvengard_ecs, :startup_system_run, :start | :stop | :exception]`
  * `[:elvengard_ecs, :shutdown_system_run, :start | :stop | :exception]`
  * `[:elvengard_ecs, :system_run, :start | :stop | :exception]`

The system prefixes above are listed in expanded form for clarity; attach to
the corresponding event name. Partitions also emit these single lifecycle and
counter events:

  * `[:elvengard_ecs, :partition_init]`
  * `[:elvengard_ecs, :partition_shutdown]`
  * `[:elvengard_ecs, :event_drop]`

Measurements contain numeric durations and counts such as `:result_count`,
`:operation_count`, `:change_count`, `:event_count`, `:receipt_count`,
`:system_run_count`, and `:failure_count`. Metadata identifies structural
context such as backend, partition, phase, system module, event module, and
outcome. Raw events, query results, entities, components, multis, and change
maps are never included.
