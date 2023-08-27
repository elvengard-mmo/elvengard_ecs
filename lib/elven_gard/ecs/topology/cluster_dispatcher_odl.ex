defmodule ElvenGard.ECS.Topology.ClusterDispatcherOld do
  @moduledoc false
  # This is a modification of `GenStage.PartitionDispatcher`
  # but with a dynamic management for clusters

  require Logger

  @behaviour GenStage.Dispatcher

  ## GenStage.Dispatcher behaviour

  # @impl true
  def init(opts) do
    key = opts[:key] || arg_error(":key callback is required for #{inspect(__MODULE__)}")

    Logger.debug("=============> init/1")

    # state = {tag, key, waiting, pending, clusters, references, infos}
    # {:ok, state}
    {:ok, {make_ref(), key, 0, 0, %{}, %{}, %{}}}
  end

  # @impl true
  def subscribe(opts, {pid, ref}, {tag, key, waiting, pending, clusters, references, infos}) do
    cluster =
      opts[:cluster] ||
        arg_error(":cluster key is required for a consumer (can be :default)")

    Logger.debug("=============> subscribe:#{cluster}")

    if Map.get(clusters, cluster) != nil do
      arg_error("there is already a consumer for the cluster: #{cluster}")
    end

    # {pid, ref, demand_or_queue}
    clusters = Map.put(clusters, cluster, {pid, ref, 0})
    references = Map.put(references, ref, cluster)

    # Dynamically register the cluster queue
    Process.put(cluster, [])

    {:ok, 0, {tag, key, waiting, pending, clusters, references, infos}}
  end

  # @impl true
  def ask(counter, {pid, ref}, {tag, key, waiting, pending, clusters, references, infos}) do
    cluster = Map.fetch!(references, ref)
    {^pid, ^ref, demand_or_queue} = Map.fetch!(clusters, cluster)

    Logger.debug("=============> ask:#{cluster} - counter:#{counter}")

    {demand_or_queue, infos} =
      case demand_or_queue do
        demand when is_integer(demand) ->
          {demand + counter, infos}

        queue ->
          send_from_queue(queue, key, pid, ref, cluster, counter, [], infos)
      end

    clusters = Map.put(clusters, cluster, {pid, ref, demand_or_queue})
    already_sent = min(pending, counter)
    demand = counter - already_sent
    pending = pending - already_sent

    Logger.debug("waiting:#{waiting + demand} - pending:#{pending}")

    {:ok, demand, {tag, key, waiting + demand, pending, clusters, references, infos}}
  end

  # @impl true
  def dispatch(events, length, {tag, key, waiting, pending, clusters, references, infos}) do
    Logger.debug("=============> dispatch: #{length}")

    Logger.debug("before: #{length(events)} - waiting: #{waiting}")

    {deliver_later, waiting, discarded} = split_events(events, waiting, key, clusters)

    # send(self(), {:"$gen_producer", {pid, ref}, {:ask, discarded}})

    Logger.debug(
      "after: #{length(deliver_later)} - waiting: #{waiting} - discarded: #{discarded}"
    )

    clusters =
      clusters
      |> :maps.to_list()
      |> request_discarded()
      |> dispatch_per_cluster()
      |> :maps.from_list()

    {:ok, events, {tag, key, waiting, pending, clusters, references, infos}}
  end

  # @impl true
  def cancel(_from, _state) do
    raise "unimplemented"
  end

  # @impl true
  def info(_msg, _state) do
    raise "unimplemented"
  end

  ## Helpers

  defp arg_error(msg) do
    raise ArgumentError, msg
  end

  defp split_events(events, counter, key, clusters, discarded \\ [])

  defp split_events([], counter, _key, _clusters, discarded) do
    {:lists.reverse(discarded), counter, length(discarded)}
  end

  defp split_events(events, 0, _key, _clusters, discarded) do
    {:lists.reverse(discarded) ++ events, 0, length(discarded)}
  end

  defp split_events([event | events], counter, key, clusters, discarded) do
    case key.(event) do
      {event, cluster} ->
        case :erlang.get(cluster) do
          :undefined ->
            Logger.warn(
              "unknown cluster #{inspect(cluster)} computed for GenStage event " <>
                "#{inspect(event)}. The known clusters are #{inspect(Map.keys(clusters))}. " <>
                "This event has been discarded."
            )

            split_events(events, counter, key, clusters, [event | discarded])

          current ->
            Process.put(cluster, [event | current])
            split_events(events, counter - 1, key, clusters, discarded)
        end

      :none ->
        split_events(events, counter, key, clusters, discarded)

      other ->
        raise "the :key function should return {event, cluster}, got: #{inspect(other)}"
    end
  end

  defp send_from_queue(queue, _tag, pid, ref, _cluster, 0, acc, infos) do
    maybe_send(acc, pid, ref)
    {queue, infos}
  end

  defp send_from_queue(queue, tag, pid, ref, cluster, counter, acc, infos) do
    case :queue.out(queue) do
      {{:value, {^tag, info}}, queue} ->
        maybe_send(acc, pid, ref)
        infos = maybe_info(infos, info, cluster)
        send_from_queue(queue, tag, pid, ref, cluster, counter, [], infos)

      {{:value, event}, queue} ->
        send_from_queue(queue, tag, pid, ref, cluster, counter - 1, [event | acc], infos)

      {:empty, _queue} ->
        maybe_send(acc, pid, ref)
        {counter, infos}
    end
  end

  # Important: events must be in reverse order
  defp maybe_send([], _pid, _ref), do: :ok

  defp maybe_send(events, pid, ref) do
    Process.send(pid, {:"$gen_consumer", {self(), ref}, :lists.reverse(events)}, [:noconnect])
  end

  defp maybe_info(infos, info, cluster) do
    case infos do
      %{^info => {msg, [^cluster]}} ->
        send(self(), msg)
        Map.delete(infos, info)

      %{^info => {msg, clusters}} ->
        Map.put(infos, info, {msg, List.delete(clusters, cluster)})
    end
  end

  defp request_discarded(clusters) do
    Enum.each(clusters, fn
      {cluster, {pid, ref, demand_or_queue}} when is_integer(demand_or_queue) ->
        to_send = length(Process.get(cluster))

        if demand_or_queue > to_send do
          send(self(), {:"$gen_producer", {pid, ref}, {:ask, demand_or_queue - to_send}})
        end
    end)

    clusters
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

  defp split_into_queue(events, 0, acc), do: {acc, put_into_queue(events, :queue.new())}
  defp split_into_queue([], counter, acc), do: {acc, counter}

  defp split_into_queue([event | events], counter, acc),
    do: split_into_queue(events, counter - 1, [event | acc])

  defp put_into_queue(events, queue) do
    Enum.reduce(events, queue, &:queue.in/2)
  end
end
