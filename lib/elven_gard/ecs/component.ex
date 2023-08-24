defmodule ElvenGard.ECS.Component do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Component
  """

  @type t :: struct()
  @type type :: module()
  @type spec :: module() | {module() | Keyword.t()}

  ## Public API

  @doc false
  defmacro __using__(opts) do
    state = opts[:state] || raise "you must provide a `state` opts for a component"

    quote do
      defstruct unquote(state)
    end
  end

  @doc """
  Transform a component spec into the corresponding struct
  """
  def spec_to_struct(module) when is_atom(module), do: struct(module)

  def spec_to_struct({module, opts}) when is_atom(module) do
    struct!(module, opts)
  end
end
