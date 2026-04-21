defmodule ColonyCell.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: registry_name()},
      {DynamicSupervisor, strategy: :one_for_one, name: supervisor_name()},
      ColonyCell.SystemSupervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_all, name: __MODULE__.Supervisor)
  end

  defp registry_name do
    Application.fetch_env!(:colony_cell, :registry_name)
  end

  defp supervisor_name do
    Application.fetch_env!(:colony_cell, :cell_supervisor_name)
  end
end
