defmodule ElvenGard.ECS.System do
  @moduledoc """
  Behaviour for logic executed by an `ElvenGard.ECS.Topology.Partition`.

  A system may run every tick through `run/1`, react to selected event modules
  through `run/2`, or implement both callbacks. Partition startup and shutdown
  systems also use `run/1`; their context delta is respectively `:startup` or
  `:shutdown`, and shutdown contexts include the stop reason:

      defmodule MyGame.MovementSystem do
        use ElvenGard.ECS.System,
          lock_components: [MyGame.Position],
          event_subscriptions: [MyGame.MoveRequested]

        @impl true
        def run(%MyGame.MoveRequested{} = event, context) do
          # Update positions for the event and partition.
        end
      end

  The required `:lock_components` option controls which systems may share an
  execution batch. Systems with overlapping component locks are serialized.
  Use `:sync` to run a system in an isolated batch. These locks are scheduling
  metadata; they do not open a backend transaction.

  A system that commits ECS mutations can return `emit_changes/1`. Successful
  change sets remain available in later execution batches and phases through
  `context.change_sets`. They are scoped to the current tick and discarded
  after the post-tick phase.
  """

  alias ElvenGard.ECS.ChangeSet

  ## Behaviour

  @typedoc "Elapsed milliseconds for a regular tick, or a lifecycle phase."
  @type delta :: non_neg_integer() | :startup | :shutdown

  @typedoc "Lifecycle or tick phase executing the system callback."
  @type phase :: :startup | :pre_tick | :tick | :post_tick | :shutdown

  @typedoc "Context passed to every system callback."
  @type context :: %{
          optional(:reason) => any(),
          change_sets: [ChangeSet.t()],
          partition: any(),
          delta: delta(),
          phase: phase()
        }

  @opaque emitted_changes :: {:elvengard_ecs_system_changes, [ChangeSet.t()]}

  @doc "Runs once per partition tick when implemented."
  @callback run(context :: context()) :: any()

  @doc "Runs once for every subscribed event received by the partition."
  @callback run(event :: struct(), context :: context()) :: any()

  @optional_callbacks [run: 1, run: 2]

  ## Public API

  @doc """
  Returns a system result that exposes committed changes to later systems in
  the current tick.

  Empty change sets are ignored by the partition. The ECS never persists or
  carries emitted changes into another tick.
  """
  @spec emit_changes(ChangeSet.t() | [ChangeSet.t()]) :: emitted_changes()
  def emit_changes(%ChangeSet{} = change_set), do: emit_changes([change_set])

  def emit_changes(change_sets) when is_list(change_sets) do
    unless Enum.all?(change_sets, &match?(%ChangeSet{}, &1)) do
      raise ArgumentError, "emit_changes/1 expects a change set or a list of change sets"
    end

    {:elvengard_ecs_system_changes, change_sets}
  end

  @doc false
  @spec emitted_change_sets(any()) :: [ChangeSet.t()]
  def emitted_change_sets({:elvengard_ecs_system_changes, change_sets}) do
    Enum.reject(change_sets, &ChangeSet.empty?/1)
  end

  def emitted_change_sets(_result), do: []

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
