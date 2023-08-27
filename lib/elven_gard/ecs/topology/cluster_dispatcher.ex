defmodule ElvenGard.ECS.Topology.ClusterDispatcher do
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

    # state = {key, waiting, clusters, references, discarded}
    # {:ok, state}
    {:ok, {key, 0, %{}, %{}, %{}}}
  end

  # @impl true
  def subscribe(opts, {pid, ref}, {key, waiting, clusters, references, discarded}) do
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

      {:ok, 0, {key, waiting, clusters, references, discarded}}
    end
  end

  # @impl true
  def ask(counter, {pid, ref}, {key, waiting, clusters, references, discarded}) do
    cluster = Map.fetch!(references, ref)
    {^pid, ^ref, current} = Map.fetch!(clusters, cluster)

    Logger.debug("=============> ask:#{cluster} - waiting:#{waiting}")

    Logger.debug(
      "=============> ask:#{cluster} - current:#{current} - counter:#{counter} - " <>
        "demand:#{current + counter}"
    )

    demand = current + counter
    waiting = waiting + demand
    clusters = Map.put(clusters, cluster, {pid, ref, demand})

    Logger.debug("waiting:#{waiting}")

    {:ok, demand, {key, waiting, clusters, references, discarded}}
  end

  # @impl true  
  def dispatch(events, length, {key, waiting, clusters, references, discarded_events}) do
    Logger.debug("=============> dispatch: #{length} - waiting: #{waiting}")

    # Get events from discarded events if exists
    {clusters, waiting, discarded_events} =
      maybe_fetch_discarded(clusters, waiting, discarded_events)

    # Deliver now are added to the Process queue
    {deliver_later, discarded, waiting, clusters} = split_events(events, waiting, key, clusters)

    # Merge discarded packets
    discarded = Map.merge(discarded_events, discarded, fn _k, v1, v2 -> v1 ++ v2 end)

    Logger.debug(
      "later: #{length(deliver_later)} - discarded: #{map_size(discarded)} - " <>
        "waiting: #{waiting} - clusters: #{inspect(clusters)}"
    )

    # Dispatch all events and resend ask demand for discarded events
    clusters =
      clusters
      |> :maps.to_list()
      |> dispatch_per_cluster()
      |> :maps.from_list()

    {:ok, deliver_later, {key, 0, clusters, references, discarded}}
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

  defp maybe_fetch_discarded(clusters, counter, discarded) do
    clusters = :maps.to_list(clusters)
    {clusters, counter, discarded} = do_maybe_fetch_discarded(clusters, counter, discarded, [])
    {:maps.from_list(clusters), counter, discarded}
  end

  # No more cluster
  defp do_maybe_fetch_discarded([], counter, discarded, acc) do
    {acc, counter, discarded}
  end

  # No more waiting events
  defp do_maybe_fetch_discarded(clusters, 0, discarded, acc) do
    {clusters ++ acc, 0, discarded}
  end

  # The cluster is not waiting for event
  defp do_maybe_fetch_discarded(
         [{_cluster, {_pid, _ref, 0}} = value | clusters],
         counter,
         discarded,
         acc
       ) do
    do_maybe_fetch_discarded(clusters, counter, discarded, [value | acc])
  end

  # The cluster is waiting for event :)
  defp do_maybe_fetch_discarded([value | clusters], counter, discarded, acc) do
    {cluster, {pid, ref, demand}} = value

    case discarded do
      %{^cluster => [event | rest]} ->
        discarded =
          case rest do
            [] ->
              IO.puts("===================> #{cluster}")
              Map.delete(discarded, cluster)

            _ ->
              Map.put(discarded, cluster, rest)
          end

        value = {cluster, {pid, ref, demand - 1}}

        with current when is_list(current) <- :erlang.get(cluster) do
          # Add the event into the queue
          Process.put(cluster, [event | current])
        else
          e -> raise "this error should not exists: #{inspect(e)} :/"
        end

        do_maybe_fetch_discarded(clusters, counter, discarded, [value | acc])

      _ ->
        do_maybe_fetch_discarded(clusters, counter, discarded, [value | acc])
    end
  end

  defp split_events(events, counter, key, clusters, pass \\ [], discarded \\ [])

  defp split_events([], counter, key, clusters, pass, discarded) do
    {:lists.reverse(pass), discarded_to_map(key, discarded), counter, clusters}
  end

  defp split_events(events, 0, key, clusters, pass, discarded) do
    {:lists.reverse(pass) ++ events, discarded_to_map(key, discarded), 0, clusters}
  end

  defp split_events([event | events], counter, key, clusters, pass, discarded) do
    case key.(event) do
      {event, cluster} ->
        {counter, clusters, pass, discarded} =
          maybe_split_event(
            event,
            cluster,
            Map.get(clusters, cluster),
            counter,
            clusters,
            pass,
            discarded
          )

        split_events(events, counter, key, clusters, pass, discarded)

      :none ->
        split_events(events, counter, key, clusters, pass, discarded)

      other ->
        raise "the :key function should return {event, cluster}, got: #{inspect(other)}"
    end
  end

  defp maybe_split_event(event, cluster, nil, counter, clusters, pass, discarded) do
    Logger.warn(
      "unknown cluster #{inspect(cluster)} computed for GenStage event " <>
        "#{inspect(event)}. The known clusters are #{inspect(Map.keys(clusters))}. " <>
        "This event has been discarded."
    )

    {counter, clusters, pass, [event | discarded]}
  end

  defp maybe_split_event(event, _cluster, {_pid, _ref, 0}, counter, clusters, pass, discarded) do
    {counter, clusters, [event | pass], discarded}
  end

  defp maybe_split_event(event, cluster, {pid, ref, demand}, counter, clusters, pass, discarded) do
    with current when is_list(current) <- :erlang.get(cluster) do
      # Add the event into the queue
      Process.put(cluster, [event | current])

      # Update demand
      clusters = Map.put(clusters, cluster, {pid, ref, demand - 1})

      {counter - 1, clusters, pass, discarded}
    end
  end

  defp discarded_to_map(key, discarded) do
    discarded
    |> Enum.map(key)
    |> Enum.group_by(&elem(&1, 1), &elem(&1, 0))
  end

  defp dispatch_per_cluster([]), do: []

  defp dispatch_per_cluster([{cluster, {pid, ref, demand}} | rest]) do
    # Reset the consumer queue
    events = Process.put(cluster, [])

    Logger.debug(
      "   ====> dispatch_per_cluster:#{cluster} - events: #{length(events)} - demand: #{demand}"
    )

    # If discarded events resend a ask
    maybe_resend_ask(pid, ref, demand)

    # Send events to consumer
    send_events(events, pid, ref)

    [{cluster, {pid, ref, 0}} | dispatch_per_cluster(rest)]
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
