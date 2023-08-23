defmodule ElvenGard.ECS do
  @moduledoc """
  Documentation for `ElvenGard.ECS`.
  """

  defguard is_entity(entity) when is_struct(entity) and entity.__type__ == :entity
end
