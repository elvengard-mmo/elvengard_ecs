defmodule ElvenGard.ECS.Component do
  @moduledoc """
  Defines data attached to an `ElvenGard.ECS.Entity`.

  A component is a plain struct. Define one with `use ElvenGard.ECS.Component`
  and a `:state` keyword list containing its fields and defaults:

      defmodule MyGame.Position do
        use ElvenGard.ECS.Component,
          state: [map_id: nil, x: 0, y: 0]
      end

  Components do not contain their owner ID. Ownership is maintained by the
  configured backend.
  """

  @typedoc "A component struct."
  @type t :: struct()

  @typedoc "A component module."
  @type type :: module()

  @typedoc """
  A component module using its defaults, or a module with attributes used to
  build the component struct.
  """
  @type spec :: module() | {module(), Keyword.t()}

  ## Public API

  @doc false
  defmacro __using__(opts) do
    state = opts[:state] || raise "you must provide a `state` opts for a component"

    quote do
      defstruct unquote(state)
    end
  end

  @doc """
  Builds a component struct from a component specification.

  A module uses the struct defaults. A `{module, attributes}` tuple overrides
  those defaults and raises if an unknown field is provided.
  """
  @spec spec_to_struct(spec()) :: t()
  def spec_to_struct(module) when is_atom(module), do: struct(module)

  def spec_to_struct({module, opts}) when is_atom(module) do
    struct!(module, opts)
  end
end
