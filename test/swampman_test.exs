defmodule SwampmanTest do
  @moduledoc false

  use ExUnit.Case, async: true

  doctest Swampman

  describe "start_link/1" do
    test "starts the Swampman manager" do
      assert {:ok, _pid} =
               Swampman.start_link(
                 pool_size: 5,
                 overflow_size: 2,
                 worker_spec: {Agent, fn -> 0 end}
               )
    end

    test "fails with missing worker_spec" do
      assert_raise ArgumentError, fn ->
        Swampman.start_link()
      end
    end

    test "fails with invalid options" do
      assert_raise ArgumentError, fn ->
        Swampman.start_link(pool_size: -1)
      end

      assert_raise ArgumentError, fn ->
        Swampman.start_link(overflow_size: -1)
      end
    end
  end

  describe "checkout/1 and checkin/2" do
    setup do
      {:ok, manager} =
        Swampman.start_link(pool_size: 2, overflow_size: 1, worker_spec: {Agent, fn -> 0 end})

      %{manager: manager}
    end

    test "checks out and checks in a worker", %{manager: manager} do
      assert {:ok, worker} = Swampman.checkout(manager)
      assert is_pid(worker)
      assert :ok = Swampman.checkin(manager, worker)
    end

    test "returns error when no workers are available", %{manager: manager} do
      assert {:ok, _worker1} = Swampman.checkout(manager)
      assert {:ok, _worker2} = Swampman.checkout(manager)
      assert {:ok, _overflow_worker} = Swampman.checkout(manager)
      assert {:error, :no_available_worker} = Swampman.checkout(manager)
    end
  end

  describe "resize/2" do
    test "resizes the pool" do
      {:ok, manager} =
        Swampman.start_link(pool_size: 2, overflow_size: 1, worker_spec: {Agent, fn -> 0 end})

      assert :ok = Swampman.resize(manager, {:pool, 3})
      assert :ok = Swampman.resize(manager, {:pool, 1})
    end

    test "resizes the overflow" do
      {:ok, manager} =
        Swampman.start_link(pool_size: 2, overflow_size: 1, worker_spec: {Agent, fn -> 0 end})

      assert :ok = Swampman.resize(manager, {:overflow, 2})
      assert :ok = Swampman.resize(manager, {:overflow, 0})
    end

    test "fails with invalid sizes" do
      {:ok, manager} =
        Swampman.start_link(pool_size: 2, overflow_size: 1, worker_spec: {Agent, fn -> 0 end})

      assert_raise FunctionClauseError, fn ->
        Swampman.resize(manager, {:pool, 0})
      end

      assert_raise FunctionClauseError, fn ->
        Swampman.resize(manager, {:overflow, -1})
      end
    end

    test "shrink pool does not terminate checked out workers" do
      {:ok, manager} =
        Swampman.start_link(pool_size: 2, worker_spec: {Agent, fn -> 0 end})

      assert {:ok, worker1} = Swampman.checkout(manager)
      assert {:ok, worker2} = Swampman.checkout(manager)
      assert :ok = Swampman.resize(manager, {:pool, 1})
      assert 0 = Agent.get(worker1, & &1)
      assert 0 = Agent.get(worker2, & &1)
      assert :ok = Swampman.checkin(manager, worker1)
      assert :ok = Swampman.checkin(manager, worker2)
      assert {:ok, _worker3} = Swampman.checkout(manager)
      assert {:error, :no_available_worker} = Swampman.checkout(manager)
    end
  end

  describe "transaction/3" do
    test "executes a transaction with a checked out worker" do
      {:ok, manager} =
        Swampman.start_link(pool_size: 2, worker_spec: {Agent, fn -> 0 end})

      1..5
      |> Enum.map(fn _ ->
        Task.async(fn ->
          Swampman.transaction(
            manager,
            fn worker ->
              Agent.get(worker, & &1)
            end,
            block: :infinity
          )
        end)
      end)
      |> Enum.map(&Task.await(&1, 5000))
      |> Enum.each(fn result -> assert result == 0 end)
    end
  end

  describe "info/1" do
    test "returns pool information" do
      spec = {Agent, fn -> 0 end}

      {:ok, manager} =
        Swampman.start_link(pool_size: 2, overflow_size: 1, worker_spec: spec)

      info = Swampman.info(manager)

      assert info.pool.target == 2
      assert info.pool.total == 2
      assert info.pool.idle == 2
      assert info.pool.busy == 0

      assert info.overflow.size == 1
      assert info.overflow.busy == 0

      assert info.worker_spec == spec
    end
  end

  test "recovery" do
    {:ok, manager} =
      Swampman.start_link(pool_size: 2, worker_spec: {Agent, fn -> 0 end})

    {:ok, worker1} = Swampman.checkout(manager)
    Process.exit(worker1, :kill)
    :timer.sleep(100)

    info = Swampman.info(manager)

    assert info.pool.total == 2
    assert info.pool.idle == 2
    assert info.pool.busy == 0
  end
end
