defmodule ElvenGard.ECS.BundleTest do
  use ElvenGard.ECS.EntityCase, async: true

  alias ElvenGard.ECS.{Bundle, Command, Entity, Query, TestPlayerBundle}
  alias ElvenGard.ECS.Components.{BuffComponent, PlayerComponent, PositionComponent}

  ## Bundle definitions

  describe "use ElvenGard.ECS.Bundle" do
    test "generates a partial bundle struct and component metadata" do
      bundle_module =
        compile_bundle!(
          "[player: ElvenGard.ECS.Components.PlayerComponent, " <>
            "position: ElvenGard.ECS.Components.PositionComponent]"
        )

      assert struct!(bundle_module) ==
               struct!(bundle_module, entity: nil, player: :not_loaded, position: :not_loaded)

      assert bundle_module.__bundle__(:components) == [
               player: PlayerComponent,
               position: PositionComponent
             ]
    end

    test "rejects invalid component declarations" do
      assert_invalid_bundle!("[]", ~r/must declare at least one component/)
      assert_invalid_bundle!("[entity: ElvenGard.ECS.Components.PlayerComponent]", ~r/reserved/)

      assert_invalid_bundle!(
        "[player: ElvenGard.ECS.Components.PlayerComponent, " <>
          "player: ElvenGard.ECS.Components.PositionComponent]",
        ~r/names must be unique/
      )

      assert_invalid_bundle!(
        "[player: ElvenGard.ECS.Components.PlayerComponent, " <>
          "other: ElvenGard.ECS.Components.PlayerComponent]",
        ~r/modules must be unique/
      )

      assert_invalid_bundle!("[player: 42]", ~r/must be module aliases/)

      assert_invalid_bundle!(
        "[ElvenGard.ECS.Components.PlayerComponent]",
        ~r/must be a keyword list/
      )
    end
  end

  ## Query materialization

  describe "Query.all/2" do
    test "materializes selected tuple values into partial bundles" do
      partition = make_ref()

      complete_entity =
        spawn_entity(
          partition: partition,
          components: [
            {PlayerComponent, name: "Complete"},
            {PositionComponent, map_id: 42}
          ]
        )

      partial_entity =
        spawn_entity(
          partition: partition,
          components: [{PlayerComponent, name: "Partial"}]
        )

      query =
        Query.select(
          {Entity, PlayerComponent, PositionComponent},
          with: [PlayerComponent],
          partition: partition
        )

      bundles = Query.all(query, into: TestPlayerBundle)

      assert %TestPlayerBundle{
               entity: ^complete_entity,
               player: %PlayerComponent{name: "Complete"},
               position: %PositionComponent{map_id: 42},
               buff: :not_loaded
             } = find_bundle!(bundles, complete_entity)

      assert %TestPlayerBundle{
               entity: ^partial_entity,
               player: %PlayerComponent{name: "Partial"},
               position: nil,
               buff: :not_loaded
             } = find_bundle!(bundles, partial_entity)
    end

    test "requires the query return type to contain Entity" do
      partition = make_ref()
      _entity = spawn_entity(partition: partition, components: [PlayerComponent])
      query = Query.select({PlayerComponent}, partition: partition)

      assert_raise ArgumentError, ~r/must contain ElvenGard.ECS.Entity/, fn ->
        Query.all(query, into: TestPlayerBundle)
      end
    end

    test "requires a tuple return type" do
      partition = make_ref()
      _entity = spawn_entity(partition: partition, components: [PlayerComponent])
      query = Query.select(PlayerComponent, partition: partition)

      assert_raise ArgumentError, ~r/requires a tuple return type/, fn ->
        Query.all(query, into: TestPlayerBundle)
      end
    end

    test "rejects components and bundle modules outside the materialization contract" do
      partition = make_ref()

      _entity =
        spawn_entity(
          partition: partition,
          components: [PlayerComponent, PositionComponent]
        )

      query =
        Query.select(
          {Entity, PlayerComponent, PositionComponent},
          with: :selected,
          partition: partition
        )

      player_only_bundle =
        compile_bundle!("[player: ElvenGard.ECS.Components.PlayerComponent]")

      assert_raise ArgumentError, ~r/PositionComponent.*not declared/, fn ->
        Query.all(query, into: player_only_bundle)
      end

      assert_raise ArgumentError, ~r/must use ElvenGard.ECS.Bundle/, fn ->
        Query.all(query, into: URI)
      end
    end

    test "validates return type and result tuple sizes" do
      entity = spawn_entity(components: [PlayerComponent])

      assert_raise ArgumentError, ~r/must have the same size/, fn ->
        Bundle.load(TestPlayerBundle, {Entity, PlayerComponent}, {entity})
      end
    end
  end

  describe "Query.one/2" do
    test "materializes one bundle and preserves nil results" do
      partition = make_ref()

      entity =
        spawn_entity(
          partition: partition,
          components: [{PlayerComponent, name: "Only"}]
        )

      query =
        Query.select(
          {Entity, PlayerComponent},
          with: :selected,
          partition: partition
        )

      assert %TestPlayerBundle{
               entity: ^entity,
               player: %PlayerComponent{name: "Only"},
               position: :not_loaded
             } = Query.one(query, into: TestPlayerBundle)

      empty_query =
        Query.select(
          {Entity, PositionComponent},
          with: :selected,
          partition: make_ref()
        )

      assert Query.one(empty_query, into: TestPlayerBundle) == nil
    end
  end

  ## Generated bundle API

  describe "generated getters" do
    test "return components and distinguish missing from unloaded values" do
      bundle = %TestPlayerBundle{player: %PlayerComponent{}, position: nil}

      assert TestPlayerBundle.player(bundle) == %PlayerComponent{}
      assert TestPlayerBundle.position(bundle) == nil
      assert TestPlayerBundle.fetch_player(bundle) == {:ok, %PlayerComponent{}}
      assert TestPlayerBundle.fetch_position(bundle) == {:error, :not_found}
      assert TestPlayerBundle.fetch_buff(bundle) == {:error, :not_loaded}

      assert_raise ElvenGard.ECS.Bundle.NotLoadedError, fn ->
        TestPlayerBundle.buff(bundle)
      end
    end
  end

  describe "preload/3" do
    test "loads missing fields and only refreshes loaded fields when forced" do
      partition = make_ref()

      entity =
        spawn_entity(
          partition: partition,
          components: [
            {PlayerComponent, name: "Initial"},
            {PositionComponent, map_id: 42}
          ]
        )

      query =
        Query.select(
          {Entity, PlayerComponent},
          with: :selected,
          partition: partition
        )

      bundle = Query.one(query, into: TestPlayerBundle)
      bundle = TestPlayerBundle.preload(bundle, :position)

      assert TestPlayerBundle.position(bundle) == %PositionComponent{map_id: 42}

      {:ok, %PositionComponent{map_id: 84}} =
        Command.update_component(entity, PositionComponent, map_id: 84)

      assert bundle |> TestPlayerBundle.preload(:position) |> TestPlayerBundle.position() ==
               %PositionComponent{map_id: 42}

      assert bundle
             |> TestPlayerBundle.preload(:position, force: true)
             |> TestPlayerBundle.position() == %PositionComponent{map_id: 84}
    end

    test "caches absent components and can force their reload" do
      partition = make_ref()
      entity = spawn_entity(partition: partition, components: [PlayerComponent])

      query =
        Query.select(
          {Entity, PlayerComponent},
          with: :selected,
          partition: partition
        )

      bundle = query |> Query.one(into: TestPlayerBundle) |> TestPlayerBundle.preload(:buff)
      assert TestPlayerBundle.fetch_buff(bundle) == {:error, :not_found}

      {:ok, %BuffComponent{buff_id: 42}} =
        Command.add_component(entity, {BuffComponent, buff_id: 42})

      assert bundle |> TestPlayerBundle.preload(:buff) |> TestPlayerBundle.fetch_buff() ==
               {:error, :not_found}

      assert bundle
             |> TestPlayerBundle.preload(:buff, force: true)
             |> TestPlayerBundle.fetch_buff() == {:ok, %BuffComponent{buff_id: 42}}
    end

    test "loads several components at once" do
      partition = make_ref()

      _entity =
        spawn_entity(
          partition: partition,
          components: [PlayerComponent, PositionComponent, BuffComponent]
        )

      query =
        Query.select(
          {Entity, PlayerComponent},
          with: :selected,
          partition: partition
        )

      bundle =
        query
        |> Query.one(into: TestPlayerBundle)
        |> TestPlayerBundle.preload([:position, :buff])

      assert %PositionComponent{} = TestPlayerBundle.position(bundle)
      assert %BuffComponent{} = TestPlayerBundle.buff(bundle)
    end

    test "accepts component modules and validates preload options" do
      partition = make_ref()

      _entity =
        spawn_entity(
          partition: partition,
          components: [PlayerComponent, PositionComponent]
        )

      query =
        Query.select(
          {Entity, PlayerComponent},
          with: :selected,
          partition: partition
        )

      bundle = Query.one(query, into: TestPlayerBundle)

      assert %PositionComponent{} =
               bundle
               |> TestPlayerBundle.preload(PositionComponent)
               |> TestPlayerBundle.position()

      assert_raise ArgumentError, ~r/unknown bundle component/, fn ->
        TestPlayerBundle.preload(bundle, :unknown)
      end

      assert_raise ArgumentError, ~r/expected :force to be a boolean/, fn ->
        TestPlayerBundle.preload(bundle, :position, force: :yes)
      end
    end
  end

  ## Private function

  defp compile_bundle!(components_source) do
    bundle_module =
      Module.concat(ElvenGard.ECS, "RuntimeBundle#{System.unique_integer([:positive])}")

    [{^bundle_module, _bytecode}] =
      Code.compile_string("""
      defmodule #{inspect(bundle_module)} do
        use ElvenGard.ECS.Bundle, components: #{components_source}

        def new(attrs), do: ElvenGard.ECS.Entity.entity_spec(attrs)
      end
      """)

    bundle_module
  end

  defp assert_invalid_bundle!(components_source, message) do
    assert_raise ArgumentError, message, fn ->
      compile_bundle!(components_source)
    end
  end

  defp find_bundle!(bundles, entity) do
    Enum.find(bundles, &(&1.entity == entity))
  end
end
