defmodule ElvenGard.ECS.Topology.ClusterDispatcherOld2 do
  @moduledoc false
  # This is a modification of `GenStage.PartitionDispatcher`
  # but with a dynamic management for clusters

  require Logger

  @behaviour GenStage.Dispatcher

  ## GenStage.Dispatcher behaviour

  # @impl true
  def init(opts) do
    key = validate_key(opts)

    Logger.debug("=============> init/1")

    # state = {key, waiting, clusters, references, store}
    # {:ok, state}
    {:ok, {key, 0, %{}, %{}, %{}}}
  end

  # @impl true
  def subscribe(opts, {pid, ref}, {key, waiting, clusters, references, store}) do
    cluster = validate_cluster(opts)

    if cluster_exists?(clusters, cluster) do
      Logger.error("there is already a consumer for the cluster: #{cluster}")
      {:error, :already_exists}
    else
      # {pid, ref, demand}
      clusters = Map.put(clusters, cluster, {pid, ref, 0})
      references = Map.put(references, ref, cluster)

      # Dynamically register the cluster queue
      Process.put(cluster, [])

      {:ok, 0, {key, waiting, clusters, references, store}}
    end
  end

  # @impl true
  def ask(counter, {pid, ref}, {key, waiting, clusters, references, store}) do
    cluster = Map.fetch!(references, ref)
    {^pid, ^ref, current} = Map.fetch!(clusters, cluster)

    Logger.debug("=============> ask:#{cluster} - waiting:#{waiting}")

    Logger.debug(
      "=============> ask:#{cluster} - current:#{current} - counter:#{counter} - " <>
        "demand:#{current + counter}"
    )

    demand = current + counter
    waiting = waiting + counter

    # FIXME: Refacto this part lel
    {{^cluster, value}, waiting, store} =
      fetch_from_store({cluster, {pid, ref, demand}}, waiting, store)

    # Maybe send events from store
    Enum.map(clusters, fn {cluster, {pid, ref, _demand}} ->
      case Process.put(cluster, []) do
        [] -> :ok
        events -> send_events(events, pid, ref)
      end
    end)

    clusters = Map.put(clusters, cluster, value)

    Logger.debug("waiting:#{waiting}")

    {:ok, demand, {key, waiting, clusters, references, store}}
  end

  # @impl true
  def dispatch(events, length, {key, waiting, clusters, references, event_store}) do
    Logger.debug("=============> dispatch: #{length} - waiting: #{waiting}")

    # Get events from store events if exists
    {clusters, waiting, event_store} = maybe_fetch_from_store(clusters, waiting, event_store)

    # Deliver now are added to the Process queue
    {deliver_later, store, waiting, clusters} = split_events(events, waiting, key, clusters)

    # Merge store packets
    store = Map.merge(event_store, store, fn _k, v1, v2 -> v1 ++ v2 end)

    Logger.debug(
      "later: #{length(deliver_later)} - store: #{map_size(store)} - " <>
        "waiting: #{waiting} - clusters: #{inspect(clusters)}"
    )

    # Dispatch all events and resend ask demand for store events
    clusters =
      clusters
      |> :maps.to_list()
      |> dispatch_per_cluster()
      |> :maps.from_list()

    {:ok, deliver_later, {key, 0, clusters, references, store}}
  end

  ## Private helpers

  defp validate_key(opts) do
    case Keyword.get(opts, :key) do
      key when is_function(key, 1) ->
        key

      other ->
        raise ArgumentError,
              ":key option must be passed a unary function, got: #{inspect(other)}"
    end
  end

  defp validate_cluster(opts) do
    case Keyword.get(opts, :cluster) do
      cluster when not is_nil(cluster) -> cluster
      nil -> raise ArgumentError, ":cluster option is required when subscribing"
    end
  end

  defp cluster_exists?(clusters, cluster) do
    cluster in Map.keys(clusters)
  end

  defp maybe_fetch_from_store(clusters, counter, store) do
    clusters = :maps.to_list(clusters)
    {clusters, counter, store} = do_maybe_fetch_from_store(clusters, counter, store, [])
    {:maps.from_list(clusters), counter, store}
  end

  # No more cluster
  defp do_maybe_fetch_from_store([], counter, store, acc) do
    {acc, counter, store}
  end

  # No more waiting events
  defp do_maybe_fetch_from_store(clusters, 0, store, acc) do
    {clusters ++ acc, 0, store}
  end

  # The cluster is not waiting for event
  defp do_maybe_fetch_from_store(
         [{_cluster, {_pid, _ref, 0}} = value | clusters],
         counter,
         store,
         acc
       ) do
    do_maybe_fetch_from_store(clusters, counter, store, [value | acc])
  end

  # The cluster is waiting for event :)
  defp do_maybe_fetch_from_store([value | clusters], counter, store, acc) do
    {cluster, {pid, ref, demand}} = value

    case store do
      %{^cluster => [event | rest]} ->
        store =
          case rest do
            [] ->
              Map.delete(store, cluster)

            _ ->
              Map.put(store, cluster, rest)
          end

        value = {cluster, {pid, ref, demand - 1}}

        with current when is_list(current) <- :erlang.get(cluster) do
          # Add the event into the queue
          Process.put(cluster, [event | current])
        else
          e -> raise "this error should not exists: #{inspect(e)} :/"
        end

        do_maybe_fetch_from_store(clusters, counter - 1, store, [value | acc])

      _ ->
        do_maybe_fetch_from_store(clusters, counter, store, [value | acc])
    end
  end

  defp fetch_from_store({_cluster, {_pid, _ref, 0}} = value, counter, store) do
    {value, counter, store}
  end

  defp fetch_from_store(value, 0, store) do
    {value, 0, store}
  end

  defp fetch_from_store({cluster, {pid, ref, demand}} = value, counter, store) do
    case store do
      %{^cluster => [event | rest]} ->
        store =
          case rest do
            [] ->
              IO.puts("===================> #{cluster}")
              Map.delete(store, cluster)

            _ ->
              Map.put(store, cluster, rest)
          end

        with current when is_list(current) <- :erlang.get(cluster) do
          # Add the event into the queue
          Process.put(cluster, [event | current])
        else
          e -> raise "this error should not exists: #{inspect(e)} :/"
        end

        {{cluster, {pid, ref, demand - 1}}, counter - 1, store}

      _ ->
        {value, counter, store}
    end
  end

  defp split_events(events, counter, key, clusters, store \\ [])

  defp split_events([], counter, key, clusters, store) do
    {[], store_to_map(key, store), counter, clusters}
  end

  defp split_events(events, 0, key, clusters, store) do
    {events, store_to_map(key, store), 0, clusters}
  end

  defp split_events([event | events], counter, key, clusters, store) do
    case key.(event) do
      {event, cluster} ->
        {counter, clusters, store} =
          maybe_split_event(
            event,
            cluster,
            Map.get(clusters, cluster),
            counter,
            clusters,
            store
          )

        split_events(events, counter, key, clusters, store)

      :none ->
        split_events(events, counter, key, clusters, store)

      other ->
        raise "the :key function should return {event, cluster}, got: #{inspect(other)}"
    end
  end

  defp maybe_split_event(event, cluster, nil, counter, clusters, store) do
    Logger.warn(
      "unknown cluster #{inspect(cluster)} computed for GenStage event " <>
        "#{inspect(event)}. The known clusters are #{inspect(Map.keys(clusters))}. " <>
        "This event has been store."
    )

    {counter, clusters, [event | store]}
  end

  defp maybe_split_event(event, _cluster, {_pid, _ref, 0}, counter, clusters, store) do
    {counter, clusters, [event | store]}
  end

  defp maybe_split_event(event, cluster, {pid, ref, demand}, counter, clusters, store) do
    with current when is_list(current) <- :erlang.get(cluster) do
      # Add the event into the queue
      Process.put(cluster, [event | current])

      # Update demand
      clusters = Map.put(clusters, cluster, {pid, ref, demand - 1})

      {counter - 1, clusters, store}
    end
  end

  defp store_to_map(key, store) do
    store
    |> Enum.map(key)
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
  end

  defp dispatch_per_cluster([]), do: []

  defp dispatch_per_cluster([{cluster, {pid, ref, demand}} | rest]) do
    # Reset the consumer queue
    case Process.put(cluster, []) do
      [] ->
        [{cluster, value} | dispatch_per_cluster(rest)]

      events ->
        events = :lists.reverse(events)

        {events, demand_or_queue} =
          case demand_or_queue do
            demand when is_integer(demand) ->
              split_into_queue(events, demand, [])

            queue ->
              {[], put_into_queue(events, queue)}
          end

        maybe_send(events, pid, ref)
        [{cluster, {pid, ref, demand_or_queue}} | dispatch_per_cluster(rest)]
    end
  end

  defp send_events([], _pid, _ref), do: :ok

  defp send_events(events, pid, ref) do
    Logger.debug("   ====> send_events:#{length(events)} - #{inspect(events)}")
    Process.send(pid, {:"$gen_consumer", {self(), ref}, :lists.reverse(events)}, [:noconnect])
  end

  defp maybe_resend_ask(_pid, _ref, 0), do: :ok

  defp maybe_resend_ask(pid, ref, demand) do
    Logger.debug("   ====> resend_ask:#{demand}")
    send(self(), {:"$gen_producer", {pid, ref}, {:ask, demand}})
  end
end
