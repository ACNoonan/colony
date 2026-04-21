defmodule ColonyCell.CellTest do
  use ExUnit.Case, async: false

  alias ColonyCore.Event

  defp start_agent_cell(cell_id, opts \\ []) do
    {:ok, pid} = ColonyCell.start_cell(cell_id, opts)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp sample_event(id) do
    Event.new(%{
      id: id,
      type: "demo.happened",
      source: "cell.demo",
      subject: "thing-1",
      data: %{},
      correlation_id: "corr-1",
      causation_id: "corr-1"
    })
  end

  test "cells default to kind :agent" do
    cell_id = "cell-agent-#{System.unique_integer([:positive])}"
    start_agent_cell(cell_id)
    assert ColonyCell.snapshot(cell_id).kind == :agent
  end

  test "cells accept kind :system via opts" do
    cell_id = "cell-system-#{System.unique_integer([:positive])}"
    start_agent_cell(cell_id, kind: :system)
    assert ColonyCell.snapshot(cell_id).kind == :system
  end

  test "snapshot exposes handled_events count and last_sequence" do
    cell_id = "cell-snapshot-#{System.unique_integer([:positive])}"
    start_agent_cell(cell_id)

    event =
      Event.new(%{
        id: "evt-1",
        type: "demo.happened",
        source: "cell.demo",
        subject: "thing-1",
        data: %{"k" => "v"},
        correlation_id: "corr-1",
        causation_id: "corr-1",
        sequence: 3
      })

    assert {:ok, :accepted} = ColonyCell.dispatch(cell_id, event)
    snap = ColonyCell.snapshot(cell_id)
    assert snap.handled_events == 1
    assert snap.last_sequence == 3
    assert snap.kind == :agent
  end

  test "duplicate event id is a no-op" do
    cell_id = "cell-dup-#{System.unique_integer([:positive])}"
    start_agent_cell(cell_id)

    event = sample_event("evt-dup-1")
    {:ok, :accepted} = ColonyCell.dispatch(cell_id, event)
    assert {:ok, :duplicate} = ColonyCell.dispatch(cell_id, event)
  end
end
