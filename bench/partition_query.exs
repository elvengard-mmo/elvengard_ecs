# Run with `MIX_ENV=test mix run bench/partition_query.exs`.

alias ElvenGard.ECS.Components.{PlayerComponent, PositionComponent}
alias ElvenGard.ECS.{Command, Entity, Query}

room_count = String.to_integer(System.get_env("ECS_BENCH_ROOMS", "100"))
entities_per_room = String.to_integer(System.get_env("ECS_BENCH_ENTITIES_PER_ROOM", "50"))
iteration_count = String.to_integer(System.get_env("ECS_BENCH_ITERATIONS", "100"))
run_id = System.unique_integer([:positive])

{spawn_microseconds, :ok} =
  :timer.tc(fn ->
    Enum.each(1..room_count, fn room_index ->
      partition = {:bench_room, run_id, room_index}

      Enum.each(1..entities_per_room, fn entity_index ->
        spec =
          Entity.entity_spec(
            id: {:bench_entity, run_id, room_index, entity_index},
            partition: partition,
            components: [
              PlayerComponent,
              {PositionComponent, map_id: room_index}
            ]
          )

        {:ok, _entity} = Command.spawn_entity(spec)
      end)
    end)
  end)

query =
  Query.select(
    {Entity, PositionComponent},
    with: [PlayerComponent],
    partition: {:bench_room, run_id, 1}
  )

results = Query.all(query)
true = length(results) == entities_per_room

{query_microseconds, :ok} =
  :timer.tc(fn ->
    Enum.each(1..iteration_count, fn _iteration ->
      _results = Query.all(query)
    end)
  end)

total_entities = room_count * entities_per_room
average_query_microseconds = query_microseconds / iteration_count

IO.puts("""
Partition query benchmark
  rooms: #{room_count}
  total entities: #{total_entities}
  entities in selected room: #{entities_per_room}
  iterations: #{iteration_count}
  spawn time: #{Float.round(spawn_microseconds / 1_000, 2)} ms
  query total: #{Float.round(query_microseconds / 1_000, 2)} ms
  query average: #{Float.round(average_query_microseconds, 2)} µs
""")
