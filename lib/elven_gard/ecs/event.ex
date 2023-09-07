defmodule ElvenGard.ECS.Event do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.Event
  """

  @type t :: struct()

  @doc false
  defmacro __using__(opts) do
    fields =
      opts
      |> validate_fields()
      |> Keyword.put_new(:partition, nil)
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
