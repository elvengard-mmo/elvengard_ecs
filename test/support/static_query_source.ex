defmodule ElvenGard.ECS.StaticQuerySource do
  @moduledoc false

  @behaviour ElvenGard.ECS.Query.Source

  @enforce_keys [:ids]
  defstruct [:ids, :notify]

  ## Query.Source callbacks

  @impl true
  def candidate_ids(%__MODULE__{} = source, partition) do
    if source.notify do
      send(source.notify, {:query_source_resolved, partition})
    end

    source.ids
  end
end
