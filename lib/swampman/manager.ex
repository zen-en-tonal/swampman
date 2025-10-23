defmodule Swampman.Manager do
  @moduledoc false

  use GenServer

  @type t :: %__MODULE__{
          target_size: pos_integer(),
          overflow_size: non_neg_integer(),
          worker_spec: module() | {module(), any()} | {module(), any(), keyword()},
          workers: %{optional(pid()) => {:idle | :busy, reference()}},
          overflow_workers: MapSet.t(pid())
        }

  @type option ::
          {:pool_size, pos_integer()}
          | {:overflow_size, non_neg_integer()}
          | {:worker_spec, module() | {module(), any()} | {module(), any(), keyword()}}
          | GenServer.options()

  defstruct [
    :target_size,
    :overflow_size,
    :worker_spec,
    :sup_pid,
    workers: %{},
    overflow_workers: MapSet.new()
  ]

  ## Client API

  @spec start_link([option()]) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(opts \\ []) do
    opts
    |> Keyword.put_new(:pool_size, 10)
    |> Keyword.put_new(:overflow_size, 0)
    |> parse_option(%{}, [])
    |> validate_options()
    |> case do
      {:ok, init, rest} ->
        GenServer.start_link(__MODULE__, init, rest)

      {:error, reason} ->
        raise ArgumentError, "Invalid options for Swampman.Manager: #{inspect(reason)}"
    end
  end

  @spec checkout(atom() | pid() | {atom(), any()} | {:via, atom(), any()}) ::
          {:ok, pid()} | {:error, :no_available_worker}
  def checkout(manager), do: GenServer.call(manager, :checkout, :infinity)

  @spec checkin(atom() | pid() | {atom(), any()} | {:via, atom(), any()}, pid()) :: :ok
  def checkin(manager, worker) when is_pid(worker),
    do: GenServer.cast(manager, {:checkin, worker})

  @spec resize(
          atom() | pid() | {atom(), any()} | {:via, atom(), any()},
          {:pool, pos_integer()} | {:overflow, non_neg_integer()}
        ) ::
          :ok
  def resize(manager, {:pool, new_size} = size) when new_size > 0 and is_integer(new_size),
    do: GenServer.cast(manager, {:resize, size})

  def resize(manager, {:overflow, new_size} = size) when is_integer(new_size) and new_size >= 0,
    do: GenServer.cast(manager, {:resize, size})

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
          :worker_spec => module() | {module(), any()} | {module(), any(), keyword()}
        }
  def info(manager), do: GenServer.call(manager, :info)

  ## Client Helper Functions

  defp parse_option([{:pool_size, size} | tail], opts, rest) do
    parse_option(tail, Map.put(opts, :pool_size, size), rest)
  end

  defp parse_option([{:overflow_size, overflow} | tail], opts, rest) do
    parse_option(tail, Map.put(opts, :overflow_size, overflow), rest)
  end

  defp parse_option([{:worker_spec, spec} | tail], opts, rest) do
    parse_option(tail, Map.put(opts, :worker_spec, spec), rest)
  end

  defp parse_option([head | tail], opts, rest) do
    parse_option(tail, opts, [head | rest])
  end

  defp parse_option([], opts, rest) do
    opts = %__MODULE__{
      target_size: opts[:pool_size],
      overflow_size: opts[:overflow_size],
      worker_spec: opts[:worker_spec]
    }

    {opts, rest}
  end

  defp validate_options({%__MODULE__{} = opts, rest}) do
    cond do
      not is_integer(opts.target_size) or opts.target_size <= 0 ->
        {:error, :invalid_pool_size}

      not is_integer(opts.overflow_size) or opts.overflow_size < 0 ->
        {:error, :invalid_overflow_size}

      is_nil(opts.worker_spec) ->
        {:error, :missing_worker_spec}

      true ->
        {:ok, opts, rest}
    end
  end

  ## Server Callbacks

  @impl true
  def init(%__MODULE__{} = init) do
    {:ok, pid} = DynamicSupervisor.start_link(strategy: :one_for_one)

    init = %{init | sup_pid: pid}

    {:ok, init |> maybe_expand()}
  end

  @impl true
  def handle_call(:checkout, _from, %__MODULE__{} = state) do
    case pick_idle(state) do
      {pid, {:idle, ref}} ->
        {:reply, {:ok, pid}, %{state | workers: Map.put(state.workers, pid, {:busy, ref})}}

      nil ->
        if MapSet.size(state.overflow_workers) < state.overflow_size do
          {:ok, pid} = DynamicSupervisor.start_child(state.sup_pid, state.worker_spec)
          Process.monitor(pid)
          overflow_workers = MapSet.put(state.overflow_workers, pid)
          {:reply, {:ok, pid}, %{state | overflow_workers: overflow_workers}}
        else
          {:reply, {:error, :no_available_worker}, state}
        end
    end
  end

  def handle_call(:info, _from, %__MODULE__{} = state) do
    busy_workers = Enum.count(state.workers, fn {_pid, status} -> status == :busy end)
    idle_workers = map_size(state.workers) - busy_workers

    busy_overflow = MapSet.size(state.overflow_workers)

    info = %{
      pool: %{
        target: state.target_size,
        total: map_size(state.workers),
        idle: idle_workers,
        busy: busy_workers
      },
      overflow: %{
        size: state.overflow_size,
        busy: busy_overflow
      },
      worker_spec: state.worker_spec
    }

    {:reply, info, state}
  end

  @impl true
  def handle_cast({:checkin, worker}, %__MODULE__{} = state) do
    cond do
      Map.has_key?(state.workers, worker) ->
        {_, ref} = state.workers[worker]

        {:noreply,
         %{state | workers: Map.put(state.workers, worker, {:idle, ref})} |> resolve_to_target()}

      MapSet.member?(state.overflow_workers, worker) ->
        DynamicSupervisor.terminate_child(state.sup_pid, worker)
        overflow_workers = MapSet.delete(state.overflow_workers, worker)
        {:noreply, %{state | overflow_workers: overflow_workers}}

      true ->
        {:noreply, state}
    end
  end

  def handle_cast({:resize, {:pool, new_size}}, %__MODULE__{} = state) do
    {:noreply, %{state | target_size: new_size} |> resolve_to_target()}
  end

  def handle_cast({:resize, {:overflow, new_size}}, %__MODULE__{} = state) do
    {:noreply, %{state | overflow_size: new_size}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{} = state) do
    cond do
      Map.has_key?(state.workers, pid) ->
        workers = Map.delete(state.workers, pid)
        {:noreply, %{state | workers: workers} |> resolve_to_target()}

      MapSet.member?(state.overflow_workers, pid) ->
        overflow_workers = MapSet.delete(state.overflow_workers, pid)
        {:noreply, %{state | overflow_workers: overflow_workers}}

      true ->
        {:noreply, state}
    end
  end

  ## Server Helpers

  defp maybe_shrink(%__MODULE__{} = state) do
    case {map_size(state.workers) > state.target_size, pick_idle(state)} do
      {true, nil} ->
        state

      {true, {pid, _}} ->
        DynamicSupervisor.terminate_child(state.sup_pid, pid)
        workers = Map.delete(state.workers, pid)
        maybe_shrink(%{state | workers: workers})

      {false, _} ->
        state
    end
  end

  defp maybe_expand(%__MODULE__{} = state) do
    if map_size(state.workers) < state.target_size do
      {:ok, pid} = DynamicSupervisor.start_child(state.sup_pid, state.worker_spec)
      ref = Process.monitor(pid)
      workers = Map.put(state.workers, pid, {:idle, ref})
      maybe_expand(%{state | workers: workers})
    else
      state
    end
  end

  defp resolve_to_target(%__MODULE__{} = state) do
    state
    |> maybe_shrink()
    |> maybe_expand()
  end

  defp pick_idle(%__MODULE__{} = state) do
    state.workers
    |> Enum.filter(fn {_pid, {status, _ref}} -> status == :idle end)
    |> case do
      [] -> nil
      list -> Enum.random(list)
    end
  end
end
