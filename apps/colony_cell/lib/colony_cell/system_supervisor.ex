defmodule ColonyCell.SystemSupervisor do
  @moduledoc """
  Supervisor for manifest-declared system cells.

  Reads `swarm/manifest.exs` at boot, picks out cells with `kind: :system`,
  and starts one supervised child per cell based on role. If the manifest
  cannot be loaded (e.g. during some test setups), the supervisor starts
  with no children rather than preventing the whole umbrella from booting.
  """

  use Supervisor

  require Logger

  alias ColonyCore.Manifest
  alias ColonyCell.Systems

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init(children(), strategy: :one_for_one)
  end

  defp children do
    case load_manifest() do
      nil ->
        []

      manifest ->
        manifest
        |> Manifest.cells()
        |> Enum.filter(&(&1.kind == :system))
        |> Enum.flat_map(&child_specs_for/1)
    end
  end

  defp child_specs_for(%Manifest.Cell{role: "logger"} = cell) do
    [Systems.Logger.child_spec_for(cell)]
  end

  defp child_specs_for(%Manifest.Cell{} = cell) do
    Logger.warning(
      "SystemSupervisor: no handler for role #{inspect(cell.role)} (cell #{inspect(cell.name)})"
    )

    []
  end

  defp load_manifest do
    Manifest.load()
  rescue
    e ->
      Logger.warning("SystemSupervisor: manifest load failed: #{Exception.message(e)}")
      nil
  end
end
