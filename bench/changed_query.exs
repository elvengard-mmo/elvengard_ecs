# Run with `MIX_ENV=test mix run bench/changed_query.exs`.

alias ElvenGard.ECS.Components.{PlayerComponent, PositionComponent}
alias ElvenGard.ECS.{Command, Entity, Multi, Query}

entity_count = String.to_integer(System.get_env("ECS_BENCH_ENTITIES", "5_000"))
changed_count = String.to_integer(System.get_env("ECS_BENCH_CHANGED", "50"))
iteration_count = String.to_integer(System.get_env("ECS_BENCH_ITERATIONS", "500"))
partition = {:changed_query_benchmark, System.unique_integer([:positive])}

entities =
  Enum.map(1..entity_count, fn index ->
    spec =
      Entity.entity_spec(
        id: {partition, index},
        partition: partition,
        components: [PlayerComponent, {PositionComponent, pos_x: index}]
      )

    {:ok, {entity, _components}} = Command.spawn_entity(spec)
    entity
  end)

cursor = Query.cursor(partition)

multi =
  entities
  |> Enum.take(changed_count)
  |> Enum.with_index()
  |> Enum.reduce(Multi.new(), fn {entity, index}, multi ->
    Multi.update_component(multi, {:position, index}, entity, PositionComponent, pos_y: index + 1)
  end)

{:ok, _changes} = Command.transact(multi)

full_query =
  Query.select({Entity, PositionComponent},
    with: :selected,
    partition: partition
  )

changed_query =
  Query.select({Entity, PositionComponent},
    with: :selected,
    partition: partition,
    changed: [PositionComponent],
    since: cursor
  )

true = length(Query.all(full_query)) == entity_count
true = length(Query.all(changed_query)) == changed_count

measure = fn query ->
  {microseconds, :ok} =
    :timer.tc(fn ->
      Enum.each(1..iteration_count, fn _iteration ->
        _results = Query.all(query)
      end)
    end)

  microseconds / iteration_count
end

full_average = measure.(full_query)
changed_average = measure.(changed_query)

IO.puts("""
Changed query benchmark
  entities: #{entity_count}
  changed entities: #{changed_count}
  iterations: #{iteration_count}
  full query average: #{Float.round(full_average, 2)} µs
  changed query average: #{Float.round(changed_average, 2)} µs
  reduction: #{Float.round((1 - changed_average / full_average) * 100, 1)}%
""")
