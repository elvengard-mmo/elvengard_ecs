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

  defmodule SimpleEntity do
    use ExUnit.Case, async: true

    alias ElvenGard.ECS.Entity

    @behaviour ElvenGard.ECS.Entity

    @impl true
    def new(_opts \\ []), do: Entity.entity_spec()

    ## Tests

    test "can be spawned" do
      specs = new()

      assert {:ok, %Entity{} = entity} = Entity.spawn(specs)
      assert specs.id == entity.id

      assert {:error, :already_spawned} = Entity.spawn(specs)
    end

    test "can be fetched" do
      specs = new()
      {:ok, entity} = Entity.spawn(specs)

      assert {:ok, ^entity} = Entity.fetch(specs.id)
      assert {:error, :not_found} = Entity.fetch("<unknown>")
    end
  end
end
