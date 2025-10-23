defmodule Swampman do
  @moduledoc """
  Swampman is a lightweight worker pool manager for Elixir applications.

  It allows you to manage a pool of worker processes, providing functionality to check out and check in workers, as well as dynamically resize the pool.

  ## Features
    - Configurable pool size and overflow size.
    - Automatic worker process management.
    - Simple API for checking out and checking in workers.
    - Transaction support for executing functions with a checked-out worker.
    - Dynamic resizing of the worker pool.

  ## Example Usage

      # Start the Swampman manager with a pool of 10 workers and an overflow of 5
      iex> {:ok, manager} = Swampman.start_link(pool_size: 10, overflow_size: 5, worker_spec: {Agent, fn -> 0 end})
      iex> {:ok, worker} = Swampman.checkout(manager)
      iex> Agent.get(worker, & &1)
      0
      # Check the worker back into the pool
      iex> Swampman.checkin(manager, worker)
      :ok
      # Execute a function within a transaction
      iex> Swampman.transaction(manager, fn worker ->
      ...> Agent.get(worker, & &1)
      ...> end, block: :infinity)
      0
      # Resize the pool to 15 workers
      iex> Swampman.resize(manager, {:pool, 15})
      :ok
      # Resize the overflow to 10 workers
      iex> Swampman.resize(manager, {:overflow, 10})
      :ok

  """

  alias Swampman.Manager

  @type option ::
          {:pool_size, pos_integer()}
          | {:overflow_size, non_neg_integer()}
          | {:worker_spec, module() | {module(), any()} | {module(), any(), keyword()}}
          | GenServer.options()

  @doc """
  Starts the Swampman worker pool manager.

  ## Options
    - `:pool_size` - The initial size of the worker pool (default: 10).
    - `:overflow_size` - The maximum number of overflow workers that can be created when the pool is exhausted (default: 0).
    - `:worker_spec` - The specification for the worker processes. This can be a module name, a tuple with module and arguments, or a tuple with module, arguments, and options.
    - Any other options supported by `GenServer.start_link/3`.
  """
  @spec start_link([option()]) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(opts \\ []), do: Manager.start_link(opts)

  @doc """
  Checks out a worker from the pool.

  If no workers are available, it will attempt to create an overflow worker if the overflow limit has not been reached.
  """
  @spec checkout(atom() | pid() | {atom(), any()} | {:via, atom(), any()}) ::
          {:ok, pid()} | {:error, :no_available_worker}
  def checkout(manager), do: Manager.checkout(manager)

  @doc """
  Checks a worker back into the pool.

  The worker must have been previously checked out from the pool.
  """
  @spec checkin(atom() | pid() | {atom(), any()} | {:via, atom(), any()}, pid()) :: :ok
  def checkin(manager, worker) when is_pid(worker), do: Manager.checkin(manager, worker)

  @doc """
  Resizes the worker pool to the specified size.

  If there are more busy workers than the new pool size, the excess workers will be terminated when they are checked back in.
  """
  @spec resize(
          atom() | pid() | {atom(), any()} | {:via, atom(), any()},
          {:pool, pos_integer()} | {:overflow, non_neg_integer()}
        ) :: :ok
  def resize(manager, size), do: Manager.resize(manager, size)

  @doc """
  Returns detailed information about the pool, including the number of idle and busy workers, and the overflow status.
  """
  @spec info(atom() | pid() | {atom(), any()} | {:via, atom(), any()}) :: %{
          :pool => %{
            :target => pos_integer(),
            :total => pos_integer(),
            :idle => non_neg_integer(),
            :busy => non_neg_integer()
          },
          :overflow => %{
            :size => non_neg_integer(),
            :busy => non_neg_integer()
          },
          :worker_spec => any()
        }
  def info(manager), do: Manager.info(manager)

  @doc """
  Executes a function within a transaction, checking out a worker, executing the function, and then checking the worker back in.

  If no workers are available, it will retry if the `:block` option is set to `timeout()`.
  """
  @spec transaction(
          atom() | pid() | {atom(), any()} | {:via, atom(), any()},
          (pid() -> any()),
          block: timeout() | boolean()
        ) :: any() | {:error, :no_idle}
  def transaction(manager, fun, opts \\ []) when is_function(fun, 1) do
    case opts[:block] || false do
      false ->
        do_transaction(manager, fun)

      true ->
        do_blocking_transaction(manager, fun)

      :infinity ->
        do_blocking_transaction(manager, fun)

      timeout when is_integer(timeout) and timeout > 0 ->
        Task.async(fn ->
          do_blocking_transaction(manager, fun)
        end)
        |> Task.await(timeout)
    end
  end

  defp do_transaction(manager, fun) do
    case checkout(manager) do
      {:ok, worker} ->
        try do
          fun.(worker)
        after
          checkin(manager, worker)
        end

      {:error, :no_available_worker} ->
        {:error, :no_idle}
    end
  end

  defp do_blocking_transaction(manager, fun, retry \\ 100) do
    case do_transaction(manager, fun) do
      {:error, :no_idle} ->
        :timer.sleep(retry)
        do_blocking_transaction(manager, fun, retry)

      result ->
        result
    end
  end
end
