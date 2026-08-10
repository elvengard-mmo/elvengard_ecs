# Run with `MIX_ENV=test mix run bench/chunk_membership_query.exs`.

alias ElvenGard.ECS.Components.PositionComponent
alias ElvenGard.ECS.{Command, Entity, Query}

entity_count = String.to_integer(System.get_env("ECS_BENCH_ENTITIES", "10000"))
iteration_count = String.to_integer(System.get_env("ECS_BENCH_ITERATIONS", "20"))
grid_width = 20
partition = {:chunk_bench, System.unique_integer([:positive])}

visible_chunks =
  for chunk_x <- 6..10, chunk_y <- 6..10 do
    {chunk_x, chunk_y}
  end

Enum.each(0..(entity_count - 1), fn entity_index ->
  chunk = {rem(entity_index, grid_width), rem(div(entity_index, grid_width), grid_width)}

  spec =
    Entity.entity_spec(
      id: {:chunk_bench_entity, partition, entity_index},
      partition: partition,
      components: [{PositionComponent, map_id: chunk}]
    )

  {:ok, _entity} = Command.spawn_entity(spec)
end)

baseline_query = fn ->
  Enum.flat_map(visible_chunks, fn chunk ->
    PositionComponent
    |> Query.select(
      with: [{PositionComponent, [{:==, :map_id, chunk}]}],
      partition: partition
    )
    |> Query.all()
  end)
end

membership_query =
  PositionComponent
  |> Query.select(
    with: [{PositionComponent, [{:in, :map_id, visible_chunks}]}],
    partition: partition
  )

expected_count =
  Enum.count(0..(entity_count - 1), fn entity_index ->
    chunk = {rem(entity_index, grid_width), rem(div(entity_index, grid_width), grid_width)}
    chunk in visible_chunks
  end)

^expected_count = baseline_query.() |> length()
^expected_count = membership_query |> Query.all() |> length()

{baseline_microseconds, :ok} =
  :timer.tc(fn ->
    Enum.each(1..iteration_count, fn _iteration ->
      ^expected_count = baseline_query.() |> length()
    end)
  end)

{membership_microseconds, :ok} =
  :timer.tc(fn ->
    Enum.each(1..iteration_count, fn _iteration ->
      ^expected_count = membership_query |> Query.all() |> length()
    end)
  end)

baseline_average = baseline_microseconds / iteration_count
membership_average = membership_microseconds / iteration_count

IO.puts("""
Chunk membership query benchmark
  entities: #{entity_count}
  visible chunks: #{length(visible_chunks)}
  matching entities: #{expected_count}
  iterations: #{iteration_count}
  repeated equality queries total: #{Float.round(baseline_microseconds / 1_000, 2)} ms
  repeated equality queries average: #{Float.round(baseline_average, 2)} µs
  membership query total: #{Float.round(membership_microseconds / 1_000, 2)} ms
  membership query average: #{Float.round(membership_average, 2)} µs
  speedup: #{Float.round(baseline_average / membership_average, 2)}x
""")
