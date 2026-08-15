defmodule ElvenGard.ECS.Query.Cursor do
  @moduledoc """
  Bounded partition revision captured for a later changed-component query.

  A cursor contains one monotonically increasing partition revision. It does
  not retain component values or a mutation history.
  """

  alias ElvenGard.ECS.Entity

  ## Struct

  @enforce_keys [:partition, :revision]
  defstruct [:partition, :revision]

  @type t :: %__MODULE__{
          partition: Entity.partition(),
          revision: non_neg_integer()
        }
end
