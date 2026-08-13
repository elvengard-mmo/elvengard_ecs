# Run with `taskset -c 0 mix run bench/system_change_sets.exs`.

defmodule ElvenGard.ECS.Bench.SystemChangeSets do
  alias ElvenGard.ECS.Topology.{EventSource, Partition}

  @config_key {__MODULE__, :config}

  defmodule WorkSystem do
    use ElvenGard.ECS.System, lock_components: :sync

    alias ElvenGard.ECS.{ChangeSet, Entity, System}

    @impl true
    def run(_context) do
      config = :persistent_term.get({ElvenGard.ECS.Bench.SystemChangeSets, :config})

      case config.emit? do
        false ->
          :ok

        true ->
          change_set =
            ChangeSet.add(
              ChangeSet.new(),
              make_ref(),
              {:set_parent, %Entity{id: make_ref()}, nil}
            )

          apply(System, :emit_changes, [change_set])
      end
    end
  end

  defmodule CompletionSystem do
    use ElvenGard.ECS.System, lock_components: :sync

    @impl true
    def run(context) do
      config = :persistent_term.get({ElvenGard.ECS.Bench.SystemChangeSets, :config})
      send(config.owner, {:benchmark_tick, length(Map.get(context, :change_sets, []))})
    end
  end

  defmodule BenchmarkPartition do
    use ElvenGard.ECS.Topology.Partition

    @impl true
    def setup(opts) do
      {Keyword.fetch!(opts, :id),
       systems: List.duplicate(WorkSystem, 4),
       post_tick_systems: [CompletionSystem],
       event_source: Keyword.fetch!(opts, :event_source),
       interval: 1_000_000,
       concurrency: 4}
    end
  end

  def run() do
    Application.ensure_all_started(:elvengard_ecs)
    iterations = System.get_env("ECS_BENCH_ITERATIONS", "500") |> String.to_integer()
    emit? = System.get_env("ECS_BENCH_EMIT_CHANGES", "false") == "true"
    expected_change_sets = if emit?, do: 4, else: 0
    :persistent_term.put(@config_key, %{owner: self(), emit?: emit?})

    source_name = Module.concat(__MODULE__, EventSource)
    {:ok, source} = EventSource.start_link(name: source_name)

    {:ok, partition} =
      Partition.start_link(
        {BenchmarkPartition, id: {:system_change_set_benchmark, make_ref()}, event_source: source}
      )

    try do
      true = Partition.started?(partition)
      Enum.each(1..20, fn _iteration -> run_tick(partition, expected_change_sets) end)
      :erlang.garbage_collect()

      samples =
        1..iterations
        |> Enum.map(fn _iteration ->
          {microseconds, :ok} =
            :timer.tc(fn -> run_tick(partition, expected_change_sets) end)

          microseconds
        end)
        |> Enum.sort()

      IO.inspect(
        %{
          iterations: iterations,
          systems_per_tick: 5,
          emitted_change_sets: expected_change_sets,
          average_us: Enum.sum(samples) / length(samples),
          p50_us: percentile(samples, 0.50),
          p95_us: percentile(samples, 0.95)
        },
        label: "System change-set propagation benchmark",
        pretty: true
      )
    after
      GenServer.stop(partition)
      GenServer.stop(source)
      :persistent_term.erase(@config_key)
    end
  end

  defp run_tick(partition, expected_change_sets) do
    send(partition, :tick)

    receive do
      {:benchmark_tick, ^expected_change_sets} -> :ok
    end
  end

  defp percentile(samples, percentile) do
    Enum.at(samples, max(ceil(length(samples) * percentile) - 1, 0))
  end
end

ElvenGard.ECS.Bench.SystemChangeSets.run()
