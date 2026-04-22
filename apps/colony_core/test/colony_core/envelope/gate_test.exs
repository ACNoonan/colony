defmodule ColonyCore.Envelope.GateTest do
  use ExUnit.Case, async: true

  alias ColonyCore.Event
  alias ColonyCore.Envelope.Gate
  alias ColonyCore.Manifest

  defp manifest do
    Manifest.from_raw!(%{
      cells: [
        %{
          name: "coordinator",
          kind: :agent,
          role: "coordinator",
          topic: "colony.agent.events",
          partition_scheme: {:field, :subject},
          prompt: "roles/coordinator.md",
          consumes: ["remediation.proposed"]
        }
      ]
    })
  end

  defp event(overrides \\ %{}) do
    Event.new(
      Map.merge(
        %{
          id: "evt-1",
          type: "demo.happened",
          source: "cell.demo",
          subject: "thing-1",
          data: %{},
          correlation_id: "corr-1",
          causation_id: "corr-1",
          partition_key: "thing-1"
        },
        overrides
      )
    )
  end

  describe "schema version rule" do
    test "accepts default version 1" do
      assert :ok = Gate.check(event(), "colony.agent.events", manifest())
    end

    test "rejects unknown versions" do
      e = event(%{schema_version: 99})

      assert {:error, {:bad_schema_version, %{got: 99}}} =
               Gate.check(e, "colony.agent.events", manifest())
    end
  end

  describe "prompt hash rule" do
    test "accepts nil" do
      assert :ok = Gate.check(event(%{prompt_hash: nil}), "colony.agent.events", manifest())
    end

    test "accepts a 64-char lowercase hex digest" do
      hash = String.duplicate("a", 64)
      assert :ok = Gate.check(event(%{prompt_hash: hash}), "colony.agent.events", manifest())
    end

    test "rejects wrong length" do
      assert {:error, {:bad_prompt_hash, %{got: "abc"}}} =
               Gate.check(event(%{prompt_hash: "abc"}), "colony.agent.events", manifest())
    end

    test "rejects uppercase hex" do
      hash = String.duplicate("A", 64)

      assert {:error, {:bad_prompt_hash, _}} =
               Gate.check(event(%{prompt_hash: hash}), "colony.agent.events", manifest())
    end
  end

  describe "partition rule" do
    test "accepts matching partition key" do
      e = event(%{subject: "inc-1", partition_key: "inc-1"})
      assert :ok = Gate.check(e, "colony.agent.events", manifest())
    end

    test "rejects mismatched partition key" do
      e = event(%{subject: "inc-1", partition_key: "other"})

      assert {:error, {:partition_mismatch, %{expected: "inc-1", got: "other"}}} =
               Gate.check(e, "colony.agent.events", manifest())
    end

    test "passes when partition_key is nil (emitter opts out)" do
      e = event(%{partition_key: nil})
      assert :ok = Gate.check(e, "colony.agent.events", manifest())
    end

    test "passes when topic is not in manifest" do
      e = event(%{partition_key: "anything"})
      assert :ok = Gate.check(e, "colony.unknown.topic", manifest())
    end
  end
end
