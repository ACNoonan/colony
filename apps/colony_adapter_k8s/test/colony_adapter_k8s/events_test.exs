defmodule ColonyAdapterK8s.EventsTest do
  use ExUnit.Case, async: true

  alias ColonyAdapterK8s.{Events, Fixtures}
  alias ColonyCore.Envelope.Gate
  alias ColonyCore.Event
  alias ColonyCore.Manifest

  @topic "colony.agent.events"

  defp manifest do
    Manifest.load()
  end

  defp translate_one!(name) do
    {:ok, payload} = Fixtures.load(name)

    case Events.translate(payload) do
      [%Event{} = event] -> {event, payload}
      other -> flunk("expected exactly one canonical event, got: #{inspect(other)}")
    end
  end

  describe "deployment rollout → change.detected" do
    test "maps Deployment ScalingReplicaSet to change.detected / kind=deployment" do
      {event, _} = translate_one!("rollout_scaled_checkout")

      assert event.type == "change.detected"
      assert event.subject == "checkout-api"
      assert event.source == "adapter.k8s.events"
      assert event.data["kind"] == "deployment"
      assert event.data["service.name"] == "checkout-api"
      assert event.data["k8s.deployment.name"] == "checkout-api"
      assert event.data["k8s.namespace.name"] == "prod"
      assert event.data["deployment.environment"] == "prod"
      assert event.data["deployment.revision"] == "7f3a2e1"
    end

    test "staging fixture derives environment from namespace" do
      {event, _} = translate_one!("rollout_scaled_orders")

      assert event.type == "change.detected"
      assert event.subject == "orders-api"
      assert event.data["deployment.environment"] == "staging"
      assert event.data["deployment.revision"] == "9d4c1a0"
    end
  end

  describe "crashloop → health.regressed" do
    test "maps Pod BackOff (Warning) to health.regressed / kind=crashloop" do
      {event, _} = translate_one!("crashloop_payments")

      assert event.type == "health.regressed"
      assert event.subject == "payments-api"
      assert event.source == "adapter.k8s.events"
      assert event.data["kind"] == "crashloop"
      assert event.data["service.name"] == "payments-api"
      assert event.data["k8s.pod.name"] == "payments-api-6fc98d6d4c-xqz9k"
      assert event.data["k8s.namespace.name"] == "prod"
      assert event.data["k8s.container.name"] == "api"
      assert event.data["restart_count"] == 7
    end

    test "extracts worker container and higher restart count" do
      {event, _} = translate_one!("crashloop_shipping")

      assert event.subject == "shipping-api"
      assert event.data["k8s.container.name"] == "worker"
      assert event.data["restart_count"] == 12
    end
  end

  describe "capacity.saturated" do
    test "FailedScheduling maps to capacity.saturated / kind=scheduling_failure" do
      {event, _} = translate_one!("failed_scheduling_orders")

      assert event.type == "capacity.saturated"
      assert event.subject == "orders-api"
      assert event.data["kind"] == "scheduling_failure"
      assert event.data["service.name"] == "orders-api"
      assert event.data["k8s.pod.name"] == "orders-api-7bc3df9c21-ab12q"
      assert event.data["k8s.namespace.name"] == "prod"
      assert event.data["k8s.event.reason"] == "FailedScheduling"
      assert event.data["scheduling.unavailable_nodes"] == 0
      assert event.data["scheduling.reason_hint"] == "Insufficient memory"
    end

    test "Evicted maps to capacity.saturated / kind=eviction" do
      {event, _} = translate_one!("evicted_cache")

      assert event.type == "capacity.saturated"
      assert event.subject == "cache-proxy"
      assert event.data["kind"] == "eviction"
      assert event.data["service.name"] == "cache-proxy"
      assert event.data["k8s.event.reason"] == "Evicted"
      assert event.data["eviction.node_condition"] == "DiskPressure"
    end
  end

  describe "envelope discipline" do
    for name <- [
          "rollout_scaled_checkout",
          "rollout_scaled_orders",
          "crashloop_payments",
          "crashloop_shipping",
          "failed_scheduling_orders",
          "evicted_cache"
        ] do
      @name name

      test "#{name} passes the pre-publish gate" do
        {event, _payload} = translate_one!(@name)
        assert :ok = Gate.check(event, @topic, manifest())
      end

      test "#{name} sets root correlation/causation to the same value" do
        {event, _payload} = translate_one!(@name)
        assert event.correlation_id == event.causation_id
      end

      test "#{name} sets partition_key to subject (matches topic's partition scheme)" do
        {event, _payload} = translate_one!(@name)
        assert event.partition_key == event.subject
      end

      test "#{name} dotted past-tense type" do
        {event, _payload} = translate_one!(@name)
        assert String.contains?(event.type, ".")
        # Not the literal k8s reason name
        refute String.starts_with?(event.type, "k8s.")
      end

      test "#{name} sets source to the adapter name" do
        {event, _payload} = translate_one!(@name)
        assert event.source == "adapter.k8s.events"
      end

      test "#{name} does NOT set action_key (signals aren't side effects)" do
        {event, _payload} = translate_one!(@name)
        assert is_nil(event.action_key)
      end
    end
  end

  describe "idempotency" do
    test "same payload translates to the same id twice (constitution §2)" do
      {:ok, payload} = Fixtures.load("crashloop_payments")
      [first] = Events.translate(payload)
      [second] = Events.translate(payload)
      assert first.id == second.id
      assert first.correlation_id == second.correlation_id
    end

    test "id is derived from metadata.uid so distinct upstream signals are distinct" do
      {:ok, a} = Fixtures.load("crashloop_payments")
      {:ok, b} = Fixtures.load("crashloop_shipping")
      [ea] = Events.translate(a)
      [eb] = Events.translate(b)
      refute ea.id == eb.id
    end
  end

  describe "unknown payloads" do
    test "returns [] when the payload is not a recognized k8s event" do
      assert [] = Events.translate(%{"totally" => "unrelated"})
    end

    test "skips k8s Events with reasons outside the adapter's vocabulary" do
      {:ok, payload} = Fixtures.load("rollout_scaled_checkout")
      unknown = put_in(payload, ["reason"], "SomethingNew")
      assert [] = Events.translate(unknown)
    end

    test "raises a clear error on payloads missing metadata.uid" do
      {:ok, payload} = Fixtures.load("rollout_scaled_checkout")
      broken = put_in(payload, ["metadata", "uid"], nil)

      assert_raise ArgumentError, ~r/metadata.uid/, fn ->
        Events.translate(broken)
      end
    end
  end
end
