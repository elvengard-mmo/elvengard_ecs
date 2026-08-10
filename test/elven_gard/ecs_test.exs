defmodule ElvenGard.ECSTest do
  use ExUnit.Case, async: true

  alias ElvenGard.ECS
  alias ElvenGard.ECS.TestEvent
  alias ElvenGard.ECS.Topology.EventSource

  ## Setup

  setup do
    name = :"Elixir.EventSource#{Enum.random(1..1_000_000)}"
    %{source: start_supervised!({EventSource, [name: name]}, id: name)}
  end

  ## Events

  test "the asynchronous dispatch path does not create tracked waiters", %{source: source} do
    :ok = EventSource.subscribe(source, partition: :arena)
    event = %TestEvent{value: 7, partition: :arena}

    assert EventSource.dispatch(source, [event]) == :ok
    assert_receive {:"$gen_cast", {:events, [^event]}}

    %{waiters: waiters} = :sys.get_state(source)
    assert waiters == %{}
  end

  test "push_and_wait timestamps events without changing the asynchronous push path", %{
    source: source
  } do
    :ok = EventSource.subscribe(source, partition: :arena)
    event = %TestEvent{value: 7, partition: :other}

    dispatch =
      Task.async(fn ->
        ECS.push_and_wait(event,
          event_source: source,
          partition: :arena,
          timeout: 1_000
        )
      end)

    assert_receive {:"$gen_cast", {:tracked_events, receipt, ^source, [dispatched_event]}}
    assert dispatched_event.partition == :arena
    assert is_integer(dispatched_event.inserted_at)

    :ok = EventSource.ack(source, receipt, :arena, [])
    assert Task.await(dispatch) == {:ok, [dispatched_event]}
  end
end
