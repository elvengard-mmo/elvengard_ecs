defmodule ElvenGard.ECS.Command do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Query

  TL;DR: Write in Backend (DIRTY or Transaction depending on the context)
  """

  alias ElvenGard.ECS.{Config, Entity}

  ## Transactions

  @spec transaction((() -> result)) :: {:error, result} | {:ok, any()} when result: any()
  def transaction(query) do
    Config.backend().transaction(query)
  end

  @spec abort(any()) :: no_return()
  def abort(reason) do
    Config.backend().abort(reason)
  end

  ## Entities

  @doc """
  TODO: Documentation
  """
  @spec spawn_entity(Entity.spec()) :: {:ok, Entity.t()} | {:error, reason}
        when reason: :already_exists | :cant_set_children
  def spawn_entity(specs) when is_map(specs) do
    %{
      components: components,
      children: children
    } = specs

    fn ->
      with {:ok, entity} <- create_entity(specs),
           :ok <- set_children(entity, children),
           :ok <- add_components(entity, components) do
        entity
      else
        {:error, reason} -> abort(reason)
      end
    end
    |> transaction()
  end

  ## Components

  ## Private helpers

  defp create_entity(%{id: id, parent: parent}) do
    Config.backend().create_entity(id, parent)
  end

  defp set_children(entity, children) do
    children
    |> Enum.map(&Config.backend().set_parent(&1, entity))
    |> Enum.all?(&match?(:ok, &1))
    |> then(&if &1, do: :ok, else: {:error, :cant_set_children})
  end

  defp add_components(entity, components) do
    Enum.each(components, &Config.backend().add_component(entity, &1))
  end
end
