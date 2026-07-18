defmodule ElvenGard.ECS.MnesiaBackendTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ElvenGard.ECS.{Component, Entity, MnesiaBackend}

  test "initializes existing tables synchronously without keeping a process alive" do
    assert :ignore = MnesiaBackend.start_link([])
    assert :ok = :mnesia.wait_for_tables([Entity, Component], 0)
  end
end
