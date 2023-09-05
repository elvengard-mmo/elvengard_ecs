defmodule ElvenGard.ECS.Event do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Event
  """

  defmacro __using__(opts) do
    fields = validate_fields(opts)

    quote bind_quoted: [fields: fields], location: :keep do
      defstruct Keyword.put_new(fields, :inserted_at, nil)
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
