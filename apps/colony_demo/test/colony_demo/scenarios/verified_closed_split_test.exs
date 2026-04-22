defmodule ColonyDemo.Scenarios.VerifiedClosedSplitTest do
  @moduledoc """
  Exercises ADR-0001's `incident.resolved` → `remediation.verified` +
  `episode.closed` split across every shipped Phase 1 scenario.

  The invariants under test:

    - the applier emits `remediation.verified` after `remediation.applied`,
      with causation pointing at the applied event,
    - the coordinator emits `episode.closed` after `remediation.verified`,
      with causation pointing at the verified event,
    - the full chain (`remediation.selected` →
      `remediation.applied` → `remediation.verified` → `episode.closed`)
      shares one `correlation_id`,
    - applier and verification emits each carry a distinct, well-formed
      `action_key` (`apply:*` vs `verify:*`) so replay stays at-most-once
      on each side of the split.
  """

  use ExUnit.Case, async: true

  for scenario_module <- ColonyDemo.scenarios() do
    describe "#{inspect(scenario_module)} verified/closed split" do
      setup do
        {:ok, events: unquote(scenario_module).events()}
      end

      test "emits remediation.verified and episode.closed as two distinct events", %{
        events: events
      } do
        verified = Enum.find(events, &(&1.type == "remediation.verified"))
        closed = Enum.find(events, &(&1.type == "episode.closed"))

        assert verified, "scenario emits a remediation.verified event"
        assert closed, "scenario emits an episode.closed event"
        refute verified.id == closed.id
      end

      test "applier emits remediation.verified; coordinator emits episode.closed", %{
        events: events
      } do
        verified = Enum.find(events, &(&1.type == "remediation.verified"))
        closed = Enum.find(events, &(&1.type == "episode.closed"))

        assert String.starts_with?(verified.source, "applier."),
               "remediation.verified source #{inspect(verified.source)} must be the applier"

        assert String.starts_with?(closed.source, "coordinator."),
               "episode.closed source #{inspect(closed.source)} must be the coordinator"
      end

      test "causation chain selected → applied → verified → closed", %{events: events} do
        selected = Enum.find(events, &(&1.type == "remediation.selected"))
        applied = Enum.find(events, &(&1.type == "remediation.applied"))
        verified = Enum.find(events, &(&1.type == "remediation.verified"))
        closed = Enum.find(events, &(&1.type == "episode.closed"))

        assert applied.causation_id == selected.id
        assert verified.causation_id == applied.id
        assert closed.causation_id == verified.id
      end

      test "all four remediation events share one correlation_id", %{events: events} do
        correlations =
          events
          |> Enum.filter(
            &(&1.type in [
                "remediation.selected",
                "remediation.applied",
                "remediation.verified",
                "episode.closed"
              ])
          )
          |> Enum.map(& &1.correlation_id)
          |> Enum.uniq()

        assert length(correlations) == 1,
               "expected one correlation_id across the split; got #{inspect(correlations)}"
      end

      test "applied and verified carry distinct action_keys", %{events: events} do
        applied = Enum.find(events, &(&1.type == "remediation.applied"))
        verified = Enum.find(events, &(&1.type == "remediation.verified"))

        assert is_binary(applied.action_key)
        assert is_binary(verified.action_key)
        assert String.starts_with?(applied.action_key, "apply:")
        assert String.starts_with?(verified.action_key, "verify:")
        refute applied.action_key == verified.action_key
      end

      test "verified/closed are partitioned with the episode subject", %{events: events} do
        opened = Enum.find(events, &(&1.type == "episode.opened"))
        verified = Enum.find(events, &(&1.type == "remediation.verified"))
        closed = Enum.find(events, &(&1.type == "episode.closed"))

        assert verified.subject == opened.subject
        assert closed.subject == opened.subject
        assert verified.partition_key == opened.subject
        assert closed.partition_key == opened.subject
      end
    end
  end
end
