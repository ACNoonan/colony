defmodule ColonyCore.EventTest do
  use ExUnit.Case, async: true

  alias ColonyCore.Event

  defp base_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        id: "evt-1",
        type: "demo.happened",
        source: "cell.demo",
        subject: "thing-1",
        data: %{"k" => "v"},
        correlation_id: "corr-1",
        causation_id: "corr-1"
      },
      overrides
    )
  end

  describe "new/1" do
    test "builds an event and fills defaults" do
      event = Event.new(base_attrs())

      assert event.schema_version == 1
      assert %DateTime{} = event.recorded_at
    end

    test "raises on missing required field" do
      attrs = base_attrs() |> Map.delete(:causation_id)

      assert_raise ArgumentError, ~r/causation_id/, fn -> Event.new(attrs) end
    end
  end

  describe "prompt_hash field" do
    test "is nil by default" do
      assert Event.new(base_attrs()).prompt_hash == nil
    end

    test "round-trips through encode/decode" do
      hash = String.duplicate("a", 64)
      event = Event.new(base_attrs(%{prompt_hash: hash}))

      {:ok, decoded} = event |> Event.encode!() |> Event.decode()

      assert decoded.prompt_hash == hash
    end
  end

  describe "idempotency_key/1" do
    test "combines tenant/swarm/agent/id" do
      event =
        Event.new(
          base_attrs(%{
            tenant_id: "t",
            swarm_id: "s",
            agent_id: "a"
          })
        )

      assert Event.idempotency_key(event) == "t:s:a:evt-1"
    end
  end
end
