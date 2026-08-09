defmodule ElvenGard.ECS.Bundle do
  @moduledoc """
  Defines reusable entity specifications and typed, partially loaded entity
  aggregates.

  A bundle groups the components and relationships required to create a domain
  object. Its `new/1` callback returns a `t:ElvenGard.ECS.Entity.spec/0`, which
  can be passed directly to `ElvenGard.ECS.Command.spawn_entity/1`.

  Using this module with a component mapping also generates a bundle struct,
  typed component getters, fetchers, and `preload/3`:

      use ElvenGard.ECS.Bundle,
        components: [
          identity: MyGame.Identity,
          position: MyGame.Position
        ]

  Bundle fields distinguish components that were not selected (`:not_loaded`)
  from components that were selected but do not exist (`nil`).

  Generated getters return the component itself, return `nil` when it is known
  to be absent, and raise `ElvenGard.ECS.Bundle.NotLoadedError` when it has not
  been loaded. `preload/3` returns a new bundle and accepts `force: true` to
  refresh fields that already contain a component or `nil`.
  """

  alias ElvenGard.ECS.Bundle.{Definition, NotLoadedError}
  alias ElvenGard.ECS.{Component, Entity, Query}

  ## Types

  @typedoc "A bundle module generated with `use ElvenGard.ECS.Bundle`."
  @type bundle_module :: module()

  @typedoc "A component field declared by a bundle."
  @type component_name :: atom()

  @typedoc "A component value held by a partially loaded bundle."
  @type component_value :: Component.t() | nil | :not_loaded

  @typedoc "A user-defined bundle struct."
  @type t :: struct()

  ## Behaviour

  @doc "Builds an entity specification from application-defined attributes."
  @callback new(attrs :: Enumerable.t()) :: ElvenGard.ECS.Entity.spec()

  ## Public API

  @doc false
  defmacro __using__(opts) do
    Definition.build(opts, __CALLER__)
  end

  @doc false
  @spec load_many(bundle_module(), Query.return_type(), [tuple()]) :: [t()]
  def load_many(bundle_module, return_type, results)
      when is_atom(bundle_module) and is_list(results) do
    case is_tuple(return_type) do
      true -> Enum.map(results, &load(bundle_module, return_type, &1))
      false -> raise ArgumentError, "bundle materialization requires a tuple return type"
    end
  end

  @doc false
  @spec load(bundle_module(), tuple(), tuple()) :: t()
  def load(bundle_module, return_type, result)
      when is_atom(bundle_module) and is_tuple(return_type) and is_tuple(result) do
    return_types = Tuple.to_list(return_type)
    values = Tuple.to_list(result)

    ensure_entity_selected!(return_types)
    ensure_matching_tuple_sizes!(return_types, values)

    component_fields =
      bundle_module
      |> components!()
      |> Map.new(fn {name, component_module} -> {component_module, name} end)

    return_types
    |> Enum.zip(values)
    |> Enum.reduce(struct!(bundle_module), fn
      {Entity, entity}, bundle ->
        struct!(bundle, entity: entity)

      {component_module, component}, bundle ->
        field =
          Map.get(component_fields, component_module) ||
            raise ArgumentError,
                  "#{inspect(component_module)} is not declared by #{inspect(bundle_module)}"

        struct!(bundle, [{field, component}])
    end)
  end

  @doc false
  @spec get!(t(), component_name()) :: Component.t() | nil
  def get!(%bundle_module{} = bundle, component_name) when is_atom(component_name) do
    case fetch(bundle, component_name) do
      {:ok, component} ->
        component

      {:error, :not_found} ->
        nil

      {:error, :not_loaded} ->
        raise NotLoadedError, bundle: bundle_module, component: component_name
    end
  end

  @doc false
  @spec fetch(t(), component_name()) ::
          {:ok, Component.t()} | {:error, :not_found | :not_loaded}
  def fetch(%_{} = bundle, component_name) when is_atom(component_name) do
    case Map.fetch!(bundle, component_name) do
      :not_loaded -> {:error, :not_loaded}
      nil -> {:error, :not_found}
      component -> {:ok, component}
    end
  end

  @doc false
  @spec preload(t(), component_name() | module() | [component_name() | module()], Keyword.t()) ::
          t()
  def preload(%_{} = bundle, component_names, opts \\ []) do
    opts = Keyword.validate!(opts, force: false)
    force? = force?(Keyword.fetch!(opts, :force))
    component_names = if is_list(component_names), do: component_names, else: [component_names]
    components = components!(bundle.__struct__)

    Enum.reduce(component_names, bundle, fn component_name, bundle ->
      preload_component(bundle, components, component_name, force?)
    end)
  end

  ## Private function

  defp components!(bundle_module) do
    if function_exported?(bundle_module, :__bundle__, 1) do
      bundle_module.__bundle__(:components)
    else
      raise ArgumentError,
            "#{inspect(bundle_module)} must use ElvenGard.ECS.Bundle before it can materialize query results"
    end
  end

  defp ensure_entity_selected!(return_types) do
    case Enum.count(return_types, &(&1 == Entity)) do
      1 ->
        :ok

      _ ->
        raise ArgumentError, "a bundle query return type must contain ElvenGard.ECS.Entity once"
    end
  end

  defp ensure_matching_tuple_sizes!(return_types, values) do
    if length(return_types) != length(values) do
      raise ArgumentError, "query return type and result tuple must have the same size"
    end
  end

  defp force?(force?) when is_boolean(force?), do: force?

  defp force?(force?) do
    raise ArgumentError, "expected :force to be a boolean, got: #{inspect(force?)}"
  end

  defp preload_component(bundle, components, component_name, force?) do
    {name, component_module} = resolve_component!(components, component_name)
    current_component = Map.fetch!(bundle, name)

    case {force?, current_component} do
      {false, component} when component != :not_loaded -> bundle
      _ -> load_component(bundle, name, component_module)
    end
  end

  defp resolve_component!(components, component_name) when is_atom(component_name) do
    Enum.find(components, fn {name, component_module} ->
      name == component_name or component_module == component_name
    end) ||
      raise ArgumentError, "unknown bundle component #{inspect(component_name)}"
  end

  defp load_component(bundle, name, component_module) do
    component =
      case Query.fetch_component(bundle.entity, component_module) do
        {:ok, component} -> component
        {:error, :not_found} -> nil
      end

    struct!(bundle, [{name, component}])
  end
end
