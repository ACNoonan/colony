defmodule ColonyCell do
  @moduledoc """
  Public API for swarm cells.

  A cell is the local execution boundary for partitioned, replay-friendly work:
  state is rebuilt from the event log, duplicate events and `action_key`
  retries are handled safely, and reasoning runs against manifest-defined
  triggers. Reference demos in `colony_demo` exercise this surface; the same
  primitives apply as the runtime widens toward broader self-healing infra
  behaviors (see project `README.md` capability ladder).
  """

  alias ColonyCell.Cell
  alias ColonyCore.Manifest

  def start_cell(cell_id, opts \\ []) do
    spec = {Cell, Keyword.put(opts, :cell_id, cell_id)}
    DynamicSupervisor.start_child(supervisor_name(), spec)
  end

  @doc """
  Start (or no-op if already running) a cell for `manifest_cell` at the
  given partition value. The runtime id is `"<role>:<partition>"`.

  Returns the runtime cell_id so callers can dispatch/snapshot by it.
  """
  @spec start_for(Manifest.Cell.t(), binary()) :: {:ok, binary()} | {:error, term()}
  def start_for(%Manifest.Cell{} = manifest_cell, partition_value)
      when is_binary(partition_value) do
    cell_id = runtime_id(manifest_cell, partition_value)

    case start_cell(cell_id, prototype: manifest_cell.name) do
      {:ok, _pid} -> {:ok, cell_id}
      {:error, {:already_started, _pid}} -> {:ok, cell_id}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec runtime_id(Manifest.Cell.t(), binary()) :: binary()
  def runtime_id(%Manifest.Cell{role: role}, partition_value)
      when is_binary(partition_value) do
    "#{role}:#{partition_value}"
  end

  def dispatch(cell_id, event) do
    cell_id
    |> via()
    |> GenServer.call({:dispatch, event})
  end

  def snapshot(cell_id) do
    cell_id
    |> via()
    |> GenServer.call(:snapshot)
  end

  @doc """
  Emit an event from a cell.

  `attrs` is a map of `ColonyCore.Event.new/1` fields. The cell auto-
  stamps `:prompt_hash` from its loaded prototype (if any), defaults
  `:source` to the prototype name, and uses the cell_id as
  `:partition_key` when not set.

  Default topic is the prototype's manifest topic. Pass `topic:` in opts
  to override. Pass `bypass_gate: true` to skip the envelope gate
  (reserved for runtime-internal emits; agent code should never use it).
  """
  def emit(cell_id, attrs, opts \\ []) when is_map(attrs) do
    cell_id
    |> via()
    |> GenServer.call({:emit, attrs, opts})
  end

  def via(cell_id) do
    {:via, Registry, {registry_name(), cell_id}}
  end

  defp registry_name do
    Application.fetch_env!(:colony_cell, :registry_name)
  end

  defp supervisor_name do
    Application.fetch_env!(:colony_cell, :cell_supervisor_name)
  end
end
