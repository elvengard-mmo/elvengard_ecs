defmodule ElvenGard.ECS.Topology.ClusterDispatcher do
  @moduledoc false
  # This is a modification of `GenStage.PartitionDispatcher`
  # but with a dynamic management for clusters

  require Logger

  @behaviour GenStage.Dispatcher

  ## GenStage.Dispatcher behaviour

  # @impl true
  def init(opts) do
    hash = validate_hash(opts)

    # Logger.debug("=======> init")

    # {:ok, {hash, waiting, pending, clusters, references, discarded, demands}}
    {:ok, {hash, 0, 0, %{}, %{}, %{}, :queue.new()}}
  end

  # @impl true
  def info(_msg, {_hash, _waiting, _pending, _clusters, _references, _discarded, _demands}) do
    raise "unsupported yet"
  end

  # @impl true
  def subscribe(
        opts,
        {pid, ref},
        {hash, waiting, pending, clusters, references, discarded, demands}
      ) do
    # Logger.debug("=======> subscribe")

    cluster = validate_cluster(opts)

    if cluster_exists?(clusters, cluster) do
      Logger.error("there is already a consumer for the cluster: #{cluster}")
      {:error, :already_exists}
    else
      {demand_or_queue, discarded} = Map.pop(discarded, cluster, 0)
      clusters = Map.put(clusters, cluster, {pid, ref, demand_or_queue})
      references = Map.put(references, ref, cluster)

      # Dynamically register the cluster queue
      Process.put(cluster, [])

      {:ok, 0, {hash, waiting, pending, clusters, references, discarded, demands}}
    end
  end

  # @impl true
  def cancel({_, ref}, {hash, waiting, pending, clusters, references, discarded, demands}) do
    {cluster, references} = Map.pop(references, ref)
    {{_pid, _ref, demand_or_queue}, clusters} = Map.pop(clusters, cluster)

    case demand_or_queue do
      demand when is_integer(demand) ->
        {:ok, 0, {hash, waiting, pending + demand, clusters, references, discarded, demands}}

      queue ->
        length = :queue.len(queue)
        discarded = Map.put(discarded, cluster, queue)
        {:ok, length, {hash, waiting + length, pending, clusters, references, discarded, demands}}
    end
  end

  # @impl true
  def ask(
        counter,
        {_pid, ref},
        {hash, waiting, pending, clusters, references, discarded, demands}
      ) do
    # Logger.debug("=======> ask")

    cluster = Map.fetch!(references, ref)
    {pid, ref, demand_or_queue} = Map.fetch!(clusters, cluster)

    {demand_or_queue, _already_sent} =
      case demand_or_queue do
        demand when is_integer(demand) ->
          {demand + counter, 0}

        queue ->
          send_from_queue(queue, pid, ref, cluster, counter)
      end

    clusters = Map.put(clusters, cluster, {pid, ref, demand_or_queue})
    already_sent = min(pending, counter)
    demand = counter - already_sent
    pending = pending - already_sent

    {:ok, demand, {hash, waiting + demand, pending, clusters, references, discarded, demands}}
  end

  @doc false
  def dispatch(
        events,
        _length,
        {hash, waiting, pending, clusters, references, discarded, demands}
      ) do
    # Logger.debug("=======> dispatch")

    {deliver_later, waiting, discarded} = split_events(events, waiting, hash, clusters, discarded)

    clusters =
      clusters
      |> :maps.to_list()
      |> dispatch_per_cluster()
      |> :maps.from_list()

    {:ok, deliver_later, {hash, waiting, pending, clusters, references, discarded, demands}}
  end

  ## Private helpers

  defp validate_hash(opts) do
    case Keyword.get(opts, :hash) do
      hash when is_function(hash, 1) ->
        hash

      other ->
        raise ArgumentError,
              ":hash option must be passed a unary function, got: #{inspect(other)}"
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

  defp send_from_queue(queue, pid, ref, cluster, counter, sent \\ 0, acc \\ [])

  defp send_from_queue(queue, pid, ref, _cluster, 0, sent, acc) do
    maybe_send(acc, pid, ref)
    {queue, sent}
  end

  defp send_from_queue(queue, pid, ref, cluster, counter, sent, acc) do
    case :queue.out(queue) do
      {{:value, event}, queue} ->
        send_from_queue(queue, pid, ref, cluster, counter - 1, sent + 1, [event | acc])

      {:empty, _queue} ->
        maybe_send(acc, pid, ref)
        {queue, sent}
    end
  end

  # Important: events must be in reverse order
  defp maybe_send([], _pid, _ref), do: :ok

  defp maybe_send(events, pid, ref) do
    Process.send(pid, {:"$gen_consumer", {self(), ref}, :lists.reverse(events)}, [:noconnect])
  end

  defp dispatch_per_cluster([]), do: []

  defp dispatch_per_cluster([{cluster, {pid, ref, demand_or_queue} = value} | rest]) do
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

  defp maybe_resend_ask([]), do: []

  defp maybe_resend_ask([{cluster, {pid, ref, demand_or_queue}} = cluster_info | rest]) do
    case demand_or_queue do
      demand when is_integer(demand) and demand > 0 ->
        IO.puts("   ====> resend_ask:#{demand} for #{cluster}")
        send(self(), {:"$gen_producer", {pid, ref}, {:ask, demand}})
        [{cluster, {pid, ref, 0}} | dispatch_per_cluster(rest)]

      _ ->
        [cluster_info | dispatch_per_cluster(rest)]
    end
  end

  defp split_into_queue(events, 0, acc), do: {acc, put_into_queue(events, :queue.new())}
  defp split_into_queue([], counter, acc), do: {acc, counter}

  defp split_into_queue([event | events], counter, acc),
    do: split_into_queue(events, counter - 1, [event | acc])

  defp put_into_queue(events, queue) do
    Enum.reduce(events, queue, &:queue.in/2)
  end

  defp split_events(events, 0, _hash, _clusters, discarded), do: {events, 0, discarded}
  defp split_events([], counter, _hash, _clusters, discarded), do: {[], counter, discarded}

  defp split_events([event | events], counter, hash, clusters, discarded) do
    case hash.(event) do
      {event, cluster} ->
        case :erlang.get(cluster) do
          :undefined ->
            Logger.warn(
              "unknown cluster #{inspect(cluster)} computed for GenStage event " <>
                "#{inspect(event)}. The known clusters are #{inspect(Map.keys(clusters))}. " <>
                "This event has been stored for later use"
            )

            split_events(
              events,
              counter,
              hash,
              clusters,
              Map.update(discarded, cluster, :queue.new(), &:queue.in(event, &1))
            )

          current ->
            Process.put(cluster, [event | current])
            split_events(events, counter - 1, hash, clusters, discarded)
        end

      :none ->
        split_events(events, counter, hash, clusters, discarded)

      other ->
        raise "the :hash function should return {event, cluster}, got: #{inspect(other)}"
    end
  end
end
