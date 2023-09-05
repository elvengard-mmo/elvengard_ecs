defmodule ElvenGard.ECS.Topology.PartitionTest do
  use ExUnit.Case, async: true

  alias ElvenGard.ECS.Topology.EventSource
  alias ElvenGard.ECS.Topology.Partition

  ## Setup

  setup do
    name = :"Elixir.EventSource#{Enum.random(1..1_000_000)}"

    source =
      start_supervised!(
        {ElvenGard.ECS.Topology.EventSource, [name: name, hash: &Function.identity/1]},
        id: name
      )

    %{source: source}
  end

  ## Test modules

  defmodule TestPartition do
    use ElvenGard.ECS.Topology.Partition

    @impl true
    def setup(opts) do
      args = [
        event_source: Keyword.fetch!(opts, :event_source),
        systems: Keyword.get(opts, :systems, []),
        tick_rate: Keyword.get(opts, :tick_rate, 1),
        concurrency: Keyword.get(opts, :concurrency, 1)
      ]

      {:default, args}
    end
  end

  defmodule Test1Event do
    use ElvenGard.ECS.Event, fields: [:id]
  end

  defmodule Test2Event do
    use ElvenGard.ECS.Event, fields: [:id, :foo]
  end

  defmodule WithoutEventsSystem do
    # use ElvenGard.ECS.System, lock_components: []

    def __event_subscriptions__(), do: nil
    def __lock_components__(), do: []
  end

  defmodule WithEventsSystem do
    # use ElvenGard.ECS.System, lock_components: []

    def __event_subscriptions__(), do: [Test1Event, Test2Event]
    def __lock_components__(), do: []
  end

  ## Tests

  describe "expand_with_events/2" do
    test "without event subscription" do
      assert [WithoutEventsSystem] = Partition.expand_with_events(WithoutEventsSystem, [])
    end

    test "with events subscription" do
      assert [] = Partition.expand_with_events(WithEventsSystem, [])

      events = [%Test1Event{}]
      expanded = Partition.expand_with_events(WithEventsSystem, events)
      assert length(expanded) == 1
      assert {WithEventsSystem, %Test1Event{}} = Enum.at(expanded, 0)

      events = [
        %Test2Event{id: 1},
        %Test1Event{id: 2},
        %Test2Event{id: 3},
        %Test2Event{id: 4}
      ]

      expanded = Partition.expand_with_events(WithEventsSystem, events)
      assert length(expanded) == 4
      assert {WithEventsSystem, %Test2Event{id: 1}} = Enum.at(expanded, 0)
      assert {WithEventsSystem, %Test1Event{id: 2}} = Enum.at(expanded, 1)
      assert {WithEventsSystem, %Test2Event{id: 3}} = Enum.at(expanded, 2)
      assert {WithEventsSystem, %Test2Event{id: 4}} = Enum.at(expanded, 3)
    end
  end

  test "aa", %{source: source} do
    systems = [WithoutEventsSystem, WithEventsSystem, WithoutEventsSystem]
    start_supervised!({TestPartition, id: :default, event_source: source, systems: systems})

    Process.sleep(1001)

    events = [
      {%Test2Event{id: 1}, :default},
      {%Test1Event{id: 2}, :default},
      {%Test2Event{id: 3}, :default},
      {%Test2Event{id: 4}, :default}
    ]

    EventSource.dispatch(source, events)

    Process.sleep(5000)
  end
end
