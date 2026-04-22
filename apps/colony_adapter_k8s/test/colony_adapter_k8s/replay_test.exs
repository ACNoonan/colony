defmodule ColonyAdapterK8s.ReplayTest do
  use ExUnit.Case, async: true

  alias ColonyAdapterK8s.{Fixtures, Replay}
  alias ColonyCore.Event

  defmodule Collector do
    use Agent

    def start_link, do: Agent.start_link(fn -> [] end)
    def publish(agent, topic, event), do: Agent.update(agent, &[{topic, event} | &1])
    def calls(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()
  end

  defp collector do
    {:ok, pid} = Collector.start_link()
    pid
  end

  defp collect_publisher(pid), do: fn topic, event -> Collector.publish(pid, topic, event) end

  test "replay_one publishes exactly one canonical event per fixture onto the default topic" do
    pid = collector()

    assert {:ok, [%Event{} = event]} =
             Replay.replay_one("rollout_scaled_checkout", publisher: collect_publisher(pid))

    assert Collector.calls(pid) == [{"colony.agent.events", event}]
  end

  test "replay_all walks the shipped fixture corpus" do
    pid = collector()

    results = Replay.replay_all(publisher: collect_publisher(pid))

    assert length(results) == length(Fixtures.list())

    Enum.each(results, fn {name, result} ->
      assert match?({:ok, [_event]}, result),
             "fixture #{name} expected one event; got #{inspect(result)}"
    end)

    assert length(Collector.calls(pid)) == length(Fixtures.list())
  end

  test "published events round-trip through Event.decode/1 unchanged" do
    pid = collector()

    assert {:ok, [event]} =
             Replay.replay_one("crashloop_payments", publisher: collect_publisher(pid))

    encoded = Event.encode!(event)
    assert {:ok, decoded} = Event.decode(encoded)

    assert decoded.id == event.id
    assert decoded.type == event.type
    assert decoded.subject == event.subject
    assert decoded.correlation_id == event.correlation_id
    assert decoded.causation_id == event.causation_id
    assert decoded.data == event.data
  end

  test "topic override is honored" do
    pid = collector()

    assert {:ok, [_]} =
             Replay.replay_one("evicted_cache",
               topic: "colony.other.topic",
               publisher: collect_publisher(pid)
             )

    assert [{"colony.other.topic", _}] = Collector.calls(pid)
  end

  test "publish failure stops the batch" do
    publisher = fn _topic, _event -> {:error, :boom} end
    assert {:error, :boom} = Replay.replay_one("rollout_scaled_checkout", publisher: publisher)
  end
end
