defmodule ColonyCell do
  @moduledoc """
  Public API for swarm cells.

  A "cell" is the local execution island we want to scale out later across
  partitions and nodes. The demo story depends on this boundary being explicit.
  """

  alias ColonyCell.Cell

  def start_cell(cell_id, opts \\ []) do
    spec = {Cell, Keyword.put(opts, :cell_id, cell_id)}
    DynamicSupervisor.start_child(supervisor_name(), spec)
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
