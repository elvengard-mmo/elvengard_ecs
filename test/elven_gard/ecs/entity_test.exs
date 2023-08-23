defmodule ElvenGard.ECS.EntityTest do
  use ExUnit.Case, async: true

  defmodule FirstEntity do
    use ElvenGard.ECS.Entity, components: []
  end

  test "define introspection helpers" do
    assert FirstEntity.__type__() == :entity
    assert FirstEntity.__components__() == []
  end

  test "define a structure" do
    assert function_exported?(FirstEntity, :__struct__, 0)
    assert %FirstEntity{id: nil} = FirstEntity.__struct__()
  end

  test "define new/0 and new/1" do
    assert %FirstEntity{id: id} = FirstEntity.new()
    assert is_binary(id)

    assert %FirstEntity{id: id2} = FirstEntity.new()
    assert id != id2

    assert %FirstEntity{id: 123} = FirstEntity.new(123)
  end
end
