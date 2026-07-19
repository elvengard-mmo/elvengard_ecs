defmodule ElvenGard.ECS.Bundle do
  @moduledoc """
  Behaviour for modules that build reusable entity specifications.

  A bundle groups the components and relationships required to create a domain
  object. Its `new/1` callback returns a `t:ElvenGard.ECS.Entity.spec/0`, which
  can be passed directly to `ElvenGard.ECS.Command.spawn_entity/1`.
  """

  ## Types

  @typedoc "A user-defined bundle struct."
  @type t :: struct()

  ## Behaviour

  @doc "Builds an entity specification from application-defined attributes."
  @callback new(attrs :: Enumerable.t()) :: ElvenGard.ECS.Entity.spec()
end
