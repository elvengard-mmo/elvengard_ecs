defmodule ElvenGard.ECS.SystemTest do
  use ExUnit.Case, async: true

  alias ElvenGard.ECS.{ChangeSet, System}

  test "emits one or several non-empty transaction-scoped change sets" do
    empty = ChangeSet.new()
    changed = ChangeSet.add(empty, :value, {:set_parent, %ElvenGard.ECS.Entity{id: 1}, nil})

    result = System.emit_changes([empty, changed])

    assert System.emitted_change_sets(result) == [changed]
  end

  test "rejects values that are not change sets" do
    assert_raise ArgumentError, ~r/expects a change set/, fn ->
      System.emit_changes([ChangeSet.new(), :invalid])
    end

    assert_raise ArgumentError, ~r/expects a change set/, fn ->
      System.emit_changes([ChangeSet.new(), :invalid], :output)
    end
  end

  test "emits and retrieves one tick-local output" do
    changed =
      ChangeSet.new()
      |> ChangeSet.add(:value, {:set_parent, %ElvenGard.ECS.Entity{id: 1}, nil})

    result = System.emit_changes(changed, %{projection: :prepared})

    assert System.emitted_change_sets(result) == [changed]
    assert System.emitted_output(result) == {:ok, %{projection: :prepared}}

    context = %{outputs: [{__MODULE__, :first}, {OtherSystem, :latest}, {__MODULE__, :second}]}
    assert System.output(context, __MODULE__) == {:ok, :second}
    assert System.output(context, OtherSystem) == {:ok, :latest}
    assert System.output(context, MissingSystem) == :error
  end
end
