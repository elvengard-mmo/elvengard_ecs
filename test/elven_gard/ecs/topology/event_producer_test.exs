defmodule ElvenGard.ECS.Topology.EventProducerTest do
  use ExUnit.Case, async: true

  alias ElvenGard.ECS.Topology.EventProducer

  ## Setup

  setup_all do
    start_supervised!(EventProducer)
    :ok
  end

  ## Tests

  test "is globally registered" do
    assert is_pid(:global.whereis_name(EventProducer))
  end

  test "cannot be start multiple times" do
    # EventProducer is already started by the setup_all
    assert EventProducer.start_link([]) == :ignore
  end
end
