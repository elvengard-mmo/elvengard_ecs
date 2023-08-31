defmodule ElvenGard.ECS.Topology.ClusterDispatcherTest do
  use ExUnit.Case, async: true

  alias ElvenGard.ECS.Topology.ClusterDispatcher, as: D

  ## Tests

  test "subscribes, asks and cancels" do
    pid = self()
    ref = make_ref()
    disp = dispatcher(hash: &{&1, &1})

    # Subscribe, ask and cancel and leave some demand
    {:ok, 0, disp} = D.subscribe([cluster: "cluster1"], {pid, ref}, disp)
    {:ok, 10, disp} = D.ask(10, {pid, ref}, disp)
    assert {10, 0} = waiting_and_pending(disp)
    {:ok, 0, disp} = D.cancel({pid, ref}, disp)
    assert {10, 10} = waiting_and_pending(disp)

    # Subscribe again and the same demand is back
    {:ok, 0, disp} = D.subscribe([cluster: "cluster2"], {pid, ref}, disp)
    {:ok, 0, disp} = D.ask(5, {pid, ref}, disp)
    assert {10, 5} = waiting_and_pending(disp)
    {:ok, 0, disp} = D.cancel({pid, ref}, disp)
    assert {10, 10} = waiting_and_pending(disp)
  end

  test "subscribes, asks and dispatches" do
    pid = self()
    ref = make_ref()
    disp = dispatcher(hash: &{&1, :default})
    {:ok, 0, disp} = D.subscribe([cluster: :default], {pid, ref}, disp)

    {:ok, 3, disp} = D.ask(3, {pid, ref}, disp)
    {:ok, [], disp} = D.dispatch([1], 1, disp)
    assert {2, 0} = waiting_and_pending(disp)
    assert_received {:"$gen_consumer", {_, ^ref}, [1]}

    {:ok, 3, disp} = D.ask(3, {pid, ref}, disp)
    assert {5, 0} = waiting_and_pending(disp)

    {:ok, [9, 11], disp} = D.dispatch([2, 5, 6, 7, 8, 9, 11], 7, disp)
    assert {0, 0} = waiting_and_pending(disp)
    assert_received {:"$gen_consumer", {_, ^ref}, [2, 5, 6, 7, 8]}
  end

  test "subscribes, asks and dispatches to custom clusters" do
    pid = self()
    ref = make_ref()

    hash_fun = fn event ->
      {event, if(rem(event, 2) == 0, do: :even, else: :odd)}
    end

    disp = dispatcher(hash: hash_fun)

    {:ok, 0, disp} = D.subscribe([cluster: :odd], {pid, ref}, disp)

    {:ok, 3, disp} = D.ask(3, {pid, ref}, disp)
    {:ok, [], disp} = D.dispatch([1], 1, disp)
    assert {2, 0} = waiting_and_pending(disp)
    assert_received {:"$gen_consumer", {_, ^ref}, [1]}

    {:ok, 3, disp} = D.ask(3, {pid, ref}, disp)
    assert {5, 0} = waiting_and_pending(disp)

    {:ok, [15, 17], disp} = D.dispatch([5, 7, 9, 11, 13, 15, 17], 7, disp)
    assert {0, 0} = waiting_and_pending(disp)
    assert_received {:"$gen_consumer", {_, ^ref}, [5, 7, 9, 11, 13]}
  end

  test "subscribes, asks and dispatches to clusters or none" do
    pid = self()
    even_ref = make_ref()
    odd_ref = make_ref()

    hash_fun = fn event ->
      cond do
        rem(event, 3) == 0 -> :none
        rem(event, 2) == 0 -> {event, :even}
        true -> {event, :odd}
      end
    end

    disp = dispatcher(hash: hash_fun)

    {:ok, 0, disp} = D.subscribe([cluster: :even], {pid, even_ref}, disp)
    {:ok, 0, disp} = D.subscribe([cluster: :odd], {pid, odd_ref}, disp)

    {:ok, 4, disp} = D.ask(4, {pid, even_ref}, disp)
    {:ok, 4, disp} = D.ask(4, {pid, odd_ref}, disp)
    {:ok, [12], disp} = D.dispatch([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], 12, disp)

    assert_received {:"$gen_consumer", {_, ^even_ref}, [2, 4, 8, 10]}
    assert_received {:"$gen_consumer", {_, ^odd_ref}, [1, 5, 7, 11]}
    assert {0, 0} = waiting_and_pending(disp)
  end

  ## Tests

  defp dispatcher(opts) do
    {:ok, state} = D.init(opts)
    state
  end

  defp waiting_and_pending({_, waiting, pending, _, _, _, _}) do
    {waiting, pending}
  end

  defp discarded({_, _, _, _, _, discarded, _}, cluster) do
    Map.get(discarded, cluster)
  end
end
