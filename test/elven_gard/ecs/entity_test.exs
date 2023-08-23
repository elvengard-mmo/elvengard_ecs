defmodule ElvenGard.ECS.EntityTest do
  use ExUnit.Case, async: true

  alias ElvenGard.ECS.Entity

  test "define a structure" do
    assert function_exported?(Entity, :__struct__, 0)
    assert %Entity{id: nil} = Entity.__struct__()
  end

  test "define entity_spec/0 and entity_spec/1" do
    specs = Entity.entity_spec()

    assert is_map(specs)
    assert is_binary(specs.id)
    assert is_list(specs.components)
    assert is_nil(specs.parent)
    assert is_list(specs.children)
  end
end
