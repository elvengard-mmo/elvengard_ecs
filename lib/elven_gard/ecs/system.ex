defmodule ElvenGard.ECS.System do
  @moduledoc """
  TODO: Documentation for ElvenGard.ECS.System
  """

  ## Behaviour

  @type delta :: non_neg_integer() | :startup
  @type context :: %{partition: any(), delta: delta()}

  @callback run(context :: context()) :: any()
  @callback run(event :: struct(), context :: context()) :: any()

  @optional_callbacks [run: 1, run: 2]

  ## Public API

  @doc false
  defmacro __using__(opts) do
    event_modules = Keyword.get(opts, :event_subscriptions, [])
    locked_components = validate_locks(opts)

    quote location: :keep do
      @behaviour unquote(__MODULE__)
      @before_compile unquote(__MODULE__)

      def __event_subscriptions__(), do: unquote(event_modules)
      def __lock_components__(), do: unquote(locked_components)
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    run_each_frames = Module.defines?(env.module, {:run, 1})

    quote do
      def __run_each_frames__(), do: unquote(run_each_frames)
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
