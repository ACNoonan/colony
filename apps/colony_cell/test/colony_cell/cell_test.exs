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

  describe "prototype-aware cells" do
    test "loads prompt_hash from manifest when :prototype is set" do
      cell_id = "cell-proto-#{System.unique_integer([:positive])}"
      start_agent_cell(cell_id, prototype: "coordinator")

      snap = ColonyCell.snapshot(cell_id)
      assert snap.prototype == "coordinator"
      assert is_binary(snap.prompt_hash)
      assert String.length(snap.prompt_hash) == 64
    end

    test "leaves prompt_hash nil when no prototype given" do
      cell_id = "cell-noproto-#{System.unique_integer([:positive])}"
      start_agent_cell(cell_id)

      snap = ColonyCell.snapshot(cell_id)
      assert snap.prototype == nil
      assert snap.prompt_hash == nil
    end

    test "unknown prototype logs and leaves state nil" do
      cell_id = "cell-badproto-#{System.unique_integer([:positive])}"
      start_agent_cell(cell_id, prototype: "nonexistent")

      snap = ColonyCell.snapshot(cell_id)
      assert snap.prompt_hash == nil
    end
  end

  describe "prompt drift detection" do
    test "counts events whose prompt_hash disagrees with cell hash" do
      cell_id = "cell-drift-#{System.unique_integer([:positive])}"
      start_agent_cell(cell_id, prototype: "coordinator")

      divergent =
        Event.new(%{
          id: "evt-drift-1",
          type: "demo.happened",
          source: "cell.demo",
          subject: "thing-1",
          data: %{},
          correlation_id: "corr-1",
          causation_id: "corr-1",
          prompt_hash: String.duplicate("0", 64)
        })

      {:ok, :accepted} = ColonyCell.dispatch(cell_id, divergent)
      snap = ColonyCell.snapshot(cell_id)
      assert snap.drift_events == 1
    end

    test "no drift when event carries no prompt_hash" do
      cell_id = "cell-nodrift-#{System.unique_integer([:positive])}"
      start_agent_cell(cell_id, prototype: "coordinator")

      event = sample_event("evt-nodrift-1")
      {:ok, :accepted} = ColonyCell.dispatch(cell_id, event)
      assert ColonyCell.snapshot(cell_id).drift_events == 0
    end

    test "no drift when cell has no prompt_hash" do
      cell_id = "cell-cellnodrift-#{System.unique_integer([:positive])}"
      start_agent_cell(cell_id)

      stamped =
        Event.new(%{
          id: "evt-nocell-1",
          type: "demo.happened",
          source: "cell.demo",
          subject: "thing-1",
          data: %{},
          correlation_id: "corr-1",
          causation_id: "corr-1",
          prompt_hash: String.duplicate("1", 64)
        })

      {:ok, :accepted} = ColonyCell.dispatch(cell_id, stamped)
      assert ColonyCell.snapshot(cell_id).drift_events == 0
    end
  end
end
