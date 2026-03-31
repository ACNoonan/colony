defmodule ColonyDemo do
  @moduledoc """
  First reference demo: produce events into Kafka, consume them into cells,
  and show idempotent replay after a simulated crash.
  """

  require Logger

  alias ColonyCore.Event
  alias ColonyCell

  @event_topic Application.compile_env(:colony_demo, :event_topic, "colony.agent.events")

  def run do
    Logger.info("=== Colony Demo: Quote-to-Fulfillment ===")

    ensure_topic()
    start_consumer()
    # Give the consumer time to join the group and get assignments
    Process.sleep(5_000)

    events = sample_events()
    produce(events)
    # Give the consumer time to process
    Process.sleep(5_000)

    inspect_cells()
    simulate_crash_and_replay(events)
  end

  def ensure_topic do
    brokers = Application.fetch_env!(:colony_kafka, :brokers)

    case :brod.create_topics(brokers, [
           %{
             name: @event_topic,
             num_partitions: 3,
             replication_factor: 1,
             assignments: [],
             configs: []
           }
         ], %{timeout: 5_000}) do
      :ok ->
        Logger.info("Created topic #{@event_topic}")

      {:error, :topic_already_exists} ->
        Logger.info("Topic #{@event_topic} already exists")

      {:error, reason} ->
        Logger.warning("Topic creation: #{inspect(reason)}")
    end
  end

  def start_consumer do
    handler = fn event ->
      cell_id = event.partition_key || event.subject
      Logger.info("[consumer] Dispatching #{event.id} (#{event.type}) → cell:#{cell_id}")

      case ColonyCell.start_cell(cell_id) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      ColonyCell.dispatch(cell_id, event)
    end

    # Unique group ID per run so the demo always starts from latest offset
    group_id = "colony-demo-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      ColonyKafka.subscribe(@event_topic, group_id: group_id, handler: handler)

    Logger.info("Consumer subscribed to #{@event_topic} (group: #{group_id})")
  end

  def produce(events) do
    Enum.each(events, fn event ->
      :ok = ColonyKafka.publish(@event_topic, event)
      Logger.info("[producer] Published #{event.id} (#{event.type})")
    end)
  end

  def inspect_cells do
    Logger.info("=== Cell Snapshots ===")

    for {cell_id, _pid, _} <- Registry.select(ColonyCell.Registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}]) do
      snapshot = ColonyCell.snapshot(cell_id)

      Logger.info(
        "Cell #{cell_id}: #{snapshot.handled_events} events, " <>
          "last_seq=#{snapshot.last_sequence}, projections=#{inspect(snapshot.projections)}"
      )
    end
  end

  def simulate_crash_and_replay(events) do
    Logger.info("=== Simulating Cell Crash ===")

    case Registry.select(ColonyCell.Registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}]) do
      [{cell_id, pid} | _] ->
        before = ColonyCell.snapshot(cell_id)
        Logger.info("Cell #{cell_id} BEFORE crash: #{before.handled_events} events, last_seq=#{before.last_sequence}")

        Logger.info("Killing cell #{cell_id} (pid: #{inspect(pid)})")
        Process.exit(pid, :kill)
        Process.sleep(200)

        # The DynamicSupervisor may have already restarted it (temporary restart),
        # or we need to start a fresh one. Either way, get a clean cell.
        case ColonyCell.start_cell(cell_id) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        fresh = ColonyCell.snapshot(cell_id)
        Logger.info("Cell #{cell_id} after crash (fresh state): #{fresh.handled_events} events")

        # Replay the same events — idempotent cells should accept them all as new
        cell_events = Enum.filter(events, fn e -> (e.partition_key || e.subject) == cell_id end)
        Logger.info("Replaying #{length(cell_events)} events...")

        Enum.each(cell_events, fn event ->
          {:ok, status} = ColonyCell.dispatch(cell_id, event)
          Logger.info("[replay] #{event.id} (#{event.type}) → #{status}")
        end)

        after_replay = ColonyCell.snapshot(cell_id)
        Logger.info("Cell #{cell_id} AFTER replay: #{after_replay.handled_events} events, last_seq=#{after_replay.last_sequence}")
        Logger.info("Projections: #{inspect(after_replay.projections)}")

      [] ->
        Logger.warning("No cells to crash")
    end

    Logger.info("=== Demo Complete ===")
  end

  def sample_events do
    correlation = "corr-#{System.unique_integer([:positive])}"

    [
      Event.new(%{
        id: "evt-#{System.unique_integer([:positive])}",
        type: "order.submitted",
        source: "erp.orders",
        subject: "account-17",
        partition_key: "account-17",
        tenant_id: "tenant-acme",
        swarm_id: "quote-fulfillment",
        agent_id: "intake-1",
        correlation_id: correlation,
        causation_id: correlation,
        sequence: 1,
        data: %{"order_id" => "ORD-100", "sku" => "SKU-123", "quantity" => 20}
      }),
      Event.new(%{
        id: "evt-#{System.unique_integer([:positive])}",
        type: "inventory.reserved",
        source: "wms.inventory",
        subject: "account-17",
        partition_key: "account-17",
        tenant_id: "tenant-acme",
        swarm_id: "quote-fulfillment",
        agent_id: "allocator-1",
        correlation_id: correlation,
        causation_id: "evt-1",
        sequence: 2,
        data: %{"reservation_id" => "res-22", "status" => "confirmed"}
      }),
      Event.new(%{
        id: "evt-#{System.unique_integer([:positive])}",
        type: "pricing.quoted",
        source: "pricing.engine",
        subject: "account-42",
        partition_key: "account-42",
        tenant_id: "tenant-acme",
        swarm_id: "quote-fulfillment",
        agent_id: "pricer-1",
        correlation_id: correlation,
        causation_id: correlation,
        sequence: 1,
        data: %{"quote_id" => "Q-500", "total" => 4200, "currency" => "USD"}
      }),
      Event.new(%{
        id: "evt-#{System.unique_integer([:positive])}",
        type: "fulfillment.scheduled",
        source: "logistics.planner",
        subject: "account-17",
        partition_key: "account-17",
        tenant_id: "tenant-acme",
        swarm_id: "quote-fulfillment",
        agent_id: "fulfillment-1",
        correlation_id: correlation,
        causation_id: "evt-2",
        sequence: 3,
        data: %{"shipment_id" => "SHP-77", "eta" => "2026-03-10"}
      })
    ]
  end
end
