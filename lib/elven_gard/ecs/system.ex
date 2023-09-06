defmodule ElvenGard.ECS.System.WithEventSubscriptions do
  @moduledoc false
  @callback run(event :: struct(), delta :: non_neg_integer()) :: any()
end

defmodule ElvenGard.ECS.System.WithoutEventSubscriptions do
  @moduledoc false
  @callback run(delta :: non_neg_integer()) :: any()
end

defmodule ElvenGard.ECS.System do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.System
  """

  alias ElvenGard.ECS.System.{WithEventSubscriptions, WithoutEventSubscriptions}

  ## Public API

  @doc false
  defmacro __using__(opts) do
    event_modules = opts[:event_subscriptions]
    locked_components = validate_locks(opts)

    behaviour =
      case event_modules do
        nil -> WithoutEventSubscriptions
        _ -> WithEventSubscriptions
      end

    quote location: :keep do
      @behaviour unquote(behaviour)

      def __event_subscriptions__(), do: unquote(event_modules)
      def __lock_components__(), do: unquote(locked_components)
    end
  end

  ## Private functions

  defp validate_locks(opts) do
    case Keyword.get(opts, :lock_components) do
      :sync ->
        :sync

      value when is_list(value) ->
        value

      value ->
        raise ArgumentError,
              ":lock_components option must be `:sync` or a list of modules, got #{inspect(value)}"
    end
  end
end
