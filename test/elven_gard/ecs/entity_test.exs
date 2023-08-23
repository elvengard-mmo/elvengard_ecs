defmodule ElvenGard.ECS.EntityTest do
  use ExUnit.Case, async: true

  alias ElvenGard.ECS.Entity

  test "define entity_spec/0 and entity_spec/1" do
    specs = Entity.entity_spec()

    assert is_map(specs)
    assert is_binary(specs.id)
    assert is_list(specs.components)
    assert is_list(specs.parents)
    assert is_list(specs.children)
  end

  defmodule SimpleEntity do
    use ExUnit.Case, async: true
    use ElvenGard.ECS.Entity

    alias ElvenGard.ECS.Entity

    @impl true
    def new(_opts) do
      Entity.entity_spec()
    end

    ## Tests

    test "define a structure" do
      assert function_exported?(SimpleEntity, :__struct__, 0)
      assert %SimpleEntity{id: nil, __type__: :entity} = SimpleEntity.__struct__()
    end
  end
end
