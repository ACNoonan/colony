defmodule ColonyCell.ReasonerTest do
  use ExUnit.Case, async: false

  alias ColonyCore.Event
  alias ColonyCore.LLM.Fixture
  alias ColonyCore.Manifest
  alias ColonyCell.Reasoner

  setup do
    Fixture.set_fixtures([])
    :ok
  end

  defp coordinator_cell do
    Manifest.fetch_cell!(Manifest.load(), "coordinator")
  end

  defp trigger_event do
    Event.new(%{
      id: "evt-trigger-#{System.unique_integer([:positive])}",
      type: "mitigation.proposed",
      source: "specialist.rollback",
      subject: "incident-042",
      partition_key: "incident-042",
      correlation_id: "corr-1",
      causation_id: "evt-earlier",
      data: %{"strategy" => "rollback", "target_version" => "v2.3.4"}
    })
  end

  test "with no tool calls the reasoner no-ops" do
    Fixture.set_fixtures([
      %{
        content: "Waiting for more proposals.",
        tool_calls: [],
        stop_reason: :end_turn,
        usage: %{input_tokens: 10, output_tokens: 5}
      }
    ])

    assert Reasoner.reason("incident-042", trigger_event(), %{}, coordinator_cell()) == :ok
  end

  test "when LLM fails the reasoner logs and returns :ok" do
    # queue empty → fixture_exhausted error
    assert Reasoner.reason("incident-042", trigger_event(), %{}, coordinator_cell()) == :ok
  end

  test "with unknown role (no tools), reasoner skips early" do
    system_cell = %Manifest.Cell{
      name: "ghost",
      kind: :agent,
      role: "ghost_role",
      topic: "t",
      partition_scheme: :single,
      prompt: "roles/coordinator.md"
    }

    assert Reasoner.reason("x", trigger_event(), %{}, system_cell) == :ok
    # no LLM call consumed
    assert Fixture.remaining() == 0
  end
end
