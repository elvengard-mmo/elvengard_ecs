defmodule ElvenGard.ECS.Entity do
  @moduledoc """
  Identifies an object managed by ElvenGard.ECS.

  An entity only contains its ID. Components, relationships, and partitions are
  stored by the configured backend and are accessed through
  `ElvenGard.ECS.Query` and `ElvenGard.ECS.Command`.

  Use `entity_spec/1` to create the complete specification expected by
  `ElvenGard.ECS.Command.spawn_entity/1`.
  """

  alias __MODULE__
  alias ElvenGard.ECS.Component
  alias ElvenGard.ECS.UUID

  @typedoc "An entity reference."
  @type t :: %Entity{id: id()}

  @typedoc "An application-defined entity identifier."
  @type id :: any()

  @typedoc "An application-defined partition identifier."
  @type partition :: :default | any()

  @typedoc """
  Complete entity creation specification.

  Components may be modules, `{module, attributes}` specifications, or already
  constructed component structs.
  """
  @type spec :: %{
          id: id(),
          components: [Component.spec() | Component.t()],
          children: [t()],
          parent: t() | nil,
          partition: partition
        }

  @enforce_keys [:id]
  defstruct [:id]

  @doc "Returns an entity creation specification from the supplied options."
  @callback entity_spec(Keyword.t()) :: spec()

  # Public API

  @doc """
  Builds a complete entity creation specification.

  Supported options are:

    * `:id` - entity identifier; defaults to a generated UUID v4 string
    * `:components` - component specifications or component structs
    * `:children` - existing entities to attach as direct children
    * `:parent` - an existing parent entity, or `nil`
    * `:partition` - entity partition; defaults to `:default`

  The returned map is intended for `ElvenGard.ECS.Command.spawn_entity/1`.
  """
  @spec entity_spec(Keyword.t()) :: spec()
  def entity_spec(opts \\ []) do
    default = %{
      id: UUID.uuid4(),
      components: [],
      children: [],
      parent: nil,
      partition: :default
    }

    Map.merge(default, Map.new(opts))
  end
end
