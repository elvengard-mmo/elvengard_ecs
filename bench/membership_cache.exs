# Run with `ERL_FLAGS='+S 1:1' MIX_ENV=test mix run bench/membership_cache.exs`.

alias ElvenGard.ECS.Components.{PlayerComponent, PositionComponent}
alias ElvenGard.ECS.{Command, Entity, Multi, Query}

entity_count = String.to_integer(System.get_env("ECS_BENCH_ENTITIES", "500"))
member_count = String.to_integer(System.get_env("ECS_BENCH_MEMBERS", "100"))
write_count = String.to_integer(System.get_env("ECS_BENCH_WRITES", "100"))
query_iterations = String.to_integer(System.get_env("ECS_BENCH_QUERY_ITERATIONS", "300"))
write_iterations = String.to_integer(System.get_env("ECS_BENCH_WRITE_ITERATIONS", "40"))
run_id = System.unique_integer([:positive])

spawn_partition = fn mode ->
  partition = {:membership_cache_benchmark, run_id, mode}

  entities =
    Enum.map(1..entity_count, fn index ->
      components =
        case index <= member_count do
          true -> [PlayerComponent, {PositionComponent, pos_x: index}]
          false -> [{PositionComponent, pos_x: index}]
        end

      spec =
        Entity.entity_spec(
          id: {partition, index},
          partition: partition,
          components: components
        )

      {:ok, {entity, _components}} = Command.spawn_entity(spec)
      entity
    end)

  {partition, entities}
end

{untracked_partition, untracked_entities} = spawn_partition.(:untracked)
{cached_partition, cached_entities} = spawn_partition.(:cached)
{revision_partition, revision_entities} = spawn_partition.(:revision)

uncached_query = Query.select(Entity, with: [PlayerComponent], partition: untracked_partition)

cached_query =
  Query.select(Entity, with: [PlayerComponent], partition: cached_partition, cache: true)

^member_count = uncached_query |> Query.all() |> length()
^member_count = cached_query |> Query.all() |> length()
_cursor = Query.cursor(revision_partition)

build_writes = fn entities ->
  entities
  |> Enum.take(write_count)
  |> Enum.with_index()
  |> Enum.reduce(Multi.new(), fn {entity, index}, multi ->
    Multi.update_component(multi, {:position, index}, entity, PositionComponent, pos_y: index)
  end)
end

untracked_writes = build_writes.(untracked_entities)
cached_writes = build_writes.(cached_entities)
revision_writes = build_writes.(revision_entities)

measure = fn iterations, function ->
  Enum.each(1..10, fn _iteration -> function.() end)
  :erlang.garbage_collect()

  {microseconds, :ok} =
    :timer.tc(fn ->
      Enum.each(1..iterations, fn _iteration -> function.() end)
    end)

  microseconds / iterations
end

uncached_query_average =
  measure.(query_iterations, fn ->
    ^member_count = uncached_query |> Query.all() |> length()
    :ok
  end)

cached_query_average =
  measure.(query_iterations, fn ->
    ^member_count = cached_query |> Query.all() |> length()
    :ok
  end)

untracked_write_average =
  measure.(write_iterations, fn ->
    {:ok, _changes} = Command.transact(untracked_writes)
    :ok
  end)

cached_write_average =
  measure.(write_iterations, fn ->
    {:ok, _changes} = Command.transact(cached_writes)
    :ok
  end)

revision_write_average =
  measure.(write_iterations, fn ->
    {:ok, _changes} = Command.transact(revision_writes)
    :ok
  end)

IO.puts("""
Selective membership cache benchmark
  entities: #{entity_count}
  cached members: #{member_count}
  writes per transaction: #{write_count} unrelated Position components
  uncached query average: #{Float.round(uncached_query_average, 2)} µs
  cached query average: #{Float.round(cached_query_average, 2)} µs
  query reduction: #{Float.round((1 - cached_query_average / uncached_query_average) * 100, 1)}%
  untracked write average: #{Float.round(untracked_write_average, 2)} µs
  selective-cache write average: #{Float.round(cached_write_average, 2)} µs
  full-revision write average: #{Float.round(revision_write_average, 2)} µs
  selective write overhead: #{Float.round((cached_write_average / untracked_write_average - 1) * 100, 1)}%
  avoided overhead vs full revisions: #{Float.round((1 - cached_write_average / revision_write_average) * 100, 1)}%
""")
