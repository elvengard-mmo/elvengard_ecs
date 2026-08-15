defmodule ElvenGard.ECS.HasChangesCondition do
  @moduledoc false

  ## Public API

  def run?(%{change_sets: change_sets}), do: change_sets != []
end
