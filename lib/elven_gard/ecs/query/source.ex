defmodule ElvenGard.ECS.Query.Source do
  @moduledoc """
  Defines a query source that narrows ECS reads to candidate entity IDs.

  Sources are resolved when a query executes, not when it is built. The source
  must return unique or repeated IDs that belong to the requested partition;
  the ECS removes duplicates before delegating the query to its backend.

  Candidate sources are intended for secondary indexes such as spatial grids.
  They select which entities may be loaded while regular query filters still
  decide which loaded entities match.
  """

  alias ElvenGard.ECS.Entity

  @typedoc "A query source struct implemented by an integration library."
  @type t :: struct()

  @doc "Returns candidate entity IDs for one query partition."
  @callback candidate_ids(source :: t(), partition :: :any | Entity.partition()) :: [Entity.id()]

  ## Public API

  @doc false
  @spec resolve(t(), :any | Entity.partition()) :: [Entity.id()]
  def resolve(%module{} = source, partition) do
    case module.candidate_ids(source, partition) do
      ids when is_list(ids) ->
        Enum.uniq(ids)

      invalid ->
        raise ArgumentError, "query source returned invalid candidate IDs: #{inspect(invalid)}"
    end
  end
end
