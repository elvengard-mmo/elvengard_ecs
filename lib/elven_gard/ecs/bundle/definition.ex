defmodule ElvenGard.ECS.Bundle.Definition do
  @moduledoc false

  alias ElvenGard.ECS.{Bundle, Entity}

  ## Public API

  @doc false
  @spec build(Keyword.t(), Macro.Env.t()) :: Macro.t()
  def build(opts, caller) do
    components = expand_components!(opts, caller)
    fields = [entity: nil] ++ Enum.map(components, fn {name, _module} -> {name, :not_loaded} end)
    component_name_type = union_type(Enum.map(components, &elem(&1, 0)))

    typed_fields =
      [entity: quote(do: unquote(Entity).t())] ++
        Enum.map(components, fn {name, component_module} ->
          component_type = component_struct_type(component_module)
          {name, quote(do: unquote(component_type) | nil | :not_loaded)}
        end)

    accessors = Enum.map(components, &component_accessors/1)

    quote do
      @behaviour unquote(Bundle)

      @bundle_components unquote(Macro.escape(components))

      defstruct unquote(fields)

      @type component_name :: unquote(component_name_type)
      @type component_ref :: component_name() | module()
      @type t :: %__MODULE__{unquote_splicing(typed_fields)}

      @doc false
      def __bundle__(:components), do: @bundle_components

      @doc "Loads one or more component fields that are not loaded yet."
      @spec preload(t(), component_ref() | [component_ref()], Keyword.t()) :: t()
      def preload(%__MODULE__{} = bundle, components, opts \\ []) do
        unquote(Bundle).preload(bundle, components, opts)
      end

      unquote_splicing(accessors)
    end
  end

  ## Private function

  defp expand_components!(opts, caller) do
    opts
    |> Keyword.fetch!(:components)
    |> Enum.map(fn
      {name, component_module} when is_atom(name) ->
        {name, Macro.expand(component_module, caller)}

      component ->
        raise ArgumentError,
              "bundle components must be a keyword list, got: #{inspect(component)}"
    end)
    |> validate_components!()
  end

  defp validate_components!([]) do
    raise ArgumentError, "a bundle must declare at least one component"
  end

  defp validate_components!(components) do
    names = Enum.map(components, &elem(&1, 0))
    modules = Enum.map(components, &elem(&1, 1))

    cond do
      :entity in names ->
        raise ArgumentError, ":entity is reserved by ElvenGard.ECS.Bundle"

      Enum.uniq(names) != names ->
        raise ArgumentError, "bundle component names must be unique"

      Enum.uniq(modules) != modules ->
        raise ArgumentError, "bundle component modules must be unique"

      not Enum.all?(modules, &is_atom/1) ->
        raise ArgumentError, "bundle component modules must be module aliases"

      true ->
        components
    end
  end

  defp union_type([type]), do: type
  defp union_type([type | types]), do: {:|, [], [type, union_type(types)]}

  defp component_struct_type(component_module) do
    quote do
      %unquote(component_module){}
    end
  end

  defp component_accessors({name, component_module}) do
    fetch_name = String.to_atom("fetch_#{name}")
    component_type = component_struct_type(component_module)

    quote do
      @doc "Returns the loaded `#{inspect(unquote(component_module))}` component."
      @spec unquote(name)(t()) :: unquote(component_type) | nil
      def unquote(name)(%__MODULE__{} = bundle) do
        unquote(Bundle).get!(bundle, unquote(name))
      end

      @doc "Fetches the state of the `#{inspect(unquote(component_module))}` component field."
      @spec unquote(fetch_name)(t()) ::
              {:ok, unquote(component_type)} | {:error, :not_found | :not_loaded}
      def unquote(fetch_name)(%__MODULE__{} = bundle) do
        unquote(Bundle).fetch(bundle, unquote(name))
      end
    end
  end
end
