defmodule ElvenGard.ECS.Event do
  @moduledoc """
  Defines messages consumed by event-driven systems.

  Define an event with optional fields:

      defmodule MyGame.DamageTaken do
        use ElvenGard.ECS.Event, fields: [entity: nil, amount: 0]
      end

  Every event also contains:

    * `:partition` - destination partition, defaulting to `:default`
    * `:inserted_at` - monotonic dispatch timestamp, populated by
      `ElvenGard.ECS.push/2`

  Dispatch events through `ElvenGard.ECS.push/2` rather than calling an event
  source directly when the timestamp is required.
  """

  @typedoc "An event struct containing `:partition` and `:inserted_at` fields."
  @type t :: struct()

  @doc false
  defmacro __using__(opts) do
    fields =
      opts
      |> validate_fields()
      |> Keyword.put_new(:partition, :default)
      |> Keyword.put_new(:inserted_at, nil)

    quote do
      defstruct unquote(fields)
    end
  end

  ## Private helpers

  defp validate_fields(opts) do
    fields = Keyword.get(opts, :fields, [])

    unless is_list(fields) do
      raise ArgumentError, ":fields option must be a list"
    end

    fields
  end
end
