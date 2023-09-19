defmodule ElvenGard.ECS.Bundle do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Bundle

  Late write some helpers to generate:

    - structure
    - structure type
    - load function (Entity + Components to struct)
    - dump function (struct to Entity + Components)
    - Getters
    - Setters ?

  """

  ## Types

  @type t :: struct()

  ## Behaviour

  @callback new(attrs :: Enumerable.t()) :: ElvenGard.ECS.Entity.spec()
end
