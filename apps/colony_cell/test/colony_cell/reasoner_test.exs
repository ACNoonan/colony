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

  describe "plan/3 (pure, no side effects)" do
    test "returns planned emit attrs for each tool call" do
      Fixture.set_fixtures([
        %{
          content: nil,
          tool_calls: [
            %{
              id: "toolu_1",
              name: "select_mitigation",
              arguments: %{"chosen" => "rollback", "reason" => "fastest_recovery"}
            }
          ],
          stop_reason: :tool_use,
          usage: %{input_tokens: 50, output_tokens: 20}
        }
      ])

      trigger = trigger_event()
      assert {:ok, [attrs], response} = Reasoner.plan(trigger, %{}, coordinator_cell())

      assert attrs.type == "mitigation.selected"
      assert attrs.subject == trigger.subject
      assert attrs.causation_id == trigger.id
      assert attrs.correlation_id == trigger.correlation_id
      assert attrs.data["chosen"] == "rollback"
      assert response.stop_reason == :tool_use
    end

    test "returns empty list when LLM declines to call a tool" do
      Fixture.set_fixtures([
        %{
          content: "Waiting.",
          tool_calls: [],
          stop_reason: :end_turn,
          usage: %{input_tokens: 30, output_tokens: 5}
        }
      ])

      assert {:ok, [], _response} = Reasoner.plan(trigger_event(), %{}, coordinator_cell())
    end

    test "returns error on LLM failure" do
      # empty queue → :fixture_exhausted
      assert {:error, :fixture_exhausted} = Reasoner.plan(trigger_event(), %{}, coordinator_cell())
    end
  end
end
