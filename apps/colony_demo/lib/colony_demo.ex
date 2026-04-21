defmodule ColonyDemo do
  @moduledoc """
  First reference demo: incident-response swarm.

  A deployment to `checkout-svc` ships a schema change that breaks downstream
  consumers. The swarm walks five phases as Kafka events:

    1. Ingest      — `deployment.completed`, `schema.drift.detected`
    2. Fan-out     — `incident.opened`, N × `impact.scan.requested`
    3. Fan-in      — N × `impact.scan.reported`, `incident.triaged`
    4. Decide+act  — `mitigation.proposed`, `mitigation.selected`, `mitigation.applied`
    5. Close       — `incident.resolved`

  Detection events partition by service; incident events partition by
  incident_id so one incident's causal chain lands on one cell.
  """

  require Logger

  alias ColonyCore.Event
  alias ColonyCore.Manifest
  alias ColonyCell

  @event_topic Application.compile_env(:colony_demo, :event_topic, "colony.agent.events")

  def run do
    Logger.info("=== Colony Demo: Incident-Response Swarm ===")

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
    demonstrate_action_dedup(events)

    Logger.info("=== Demo Complete ===")
  end

  def ensure_topic do
    brokers = Application.fetch_env!(:colony_kafka, :brokers)

    case :brod.create_topics(
           brokers,
           [
             %{
               name: @event_topic,
               num_partitions: 3,
               replication_factor: 1,
               assignments: [],
               configs: []
             }
           ],
           %{timeout: 5_000}
         ) do
      :ok ->
        Logger.info("Created topic #{@event_topic}")

      {:error, :topic_already_exists} ->
        Logger.info("Topic #{@event_topic} already exists")

      {:error, reason} ->
        Logger.warning("Topic creation: #{inspect(reason)}")
    end
  end

  def start_consumer do
    manifest = Manifest.load()

    handler = fn event ->
      cell_id = Manifest.cell_id_for!(manifest, @event_topic, event)
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

    for {cell_id, _pid, _} <-
          Registry.select(ColonyCell.Registry, [
            {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
          ]),
        is_binary(cell_id) do
      snapshot = ColonyCell.snapshot(cell_id)

      Logger.info(
        "Cell #{cell_id}: #{snapshot.handled_events} events, " <>
          "actions=#{snapshot.applied_actions}, " <>
          "last_seq=#{snapshot.last_sequence}, projections=#{inspect(snapshot.projections)}"
      )
    end
  end

  def simulate_crash_and_replay(events) do
    Logger.info("=== Simulating Cell Crash ===")

    manifest = Manifest.load()

    agent_entries =
      ColonyCell.Registry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.filter(fn {cell_id, _pid} -> is_binary(cell_id) end)

    case agent_entries do
      [{cell_id, pid} | _] ->
        before = ColonyCell.snapshot(cell_id)

        Logger.info(
          "Cell #{cell_id} BEFORE crash: #{before.handled_events} events, " <>
            "actions=#{before.applied_actions}, last_seq=#{before.last_sequence}"
        )

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
        cell_events =
          Enum.filter(events, fn e -> Manifest.cell_id_for!(manifest, @event_topic, e) == cell_id end)

        Logger.info("Replaying #{length(cell_events)} events...")

        Enum.each(cell_events, fn event ->
          {:ok, status} = ColonyCell.dispatch(cell_id, event)
          Logger.info("[replay] #{event.id} (#{event.type}) → #{status}")
        end)

        after_replay = ColonyCell.snapshot(cell_id)

        Logger.info(
          "Cell #{cell_id} AFTER replay: #{after_replay.handled_events} events, " <>
            "actions=#{after_replay.applied_actions}, last_seq=#{after_replay.last_sequence}"
        )

        Logger.info("Projections: #{inspect(after_replay.projections)}")

      [] ->
        Logger.warning("No cells to crash")
    end
  end

  def demonstrate_action_dedup(events) do
    Logger.info("=== Action-Level Idempotency ===")

    manifest = Manifest.load()
    applied = Enum.find(events, fn e -> e.type == "mitigation.applied" end)
    cell_id = Manifest.cell_id_for!(manifest, @event_topic, applied)

    case ColonyCell.start_cell(cell_id) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    retry_event =
      Event.new(%{
        id: "evt-applied-retry-#{System.unique_integer([:positive])}",
        type: applied.type,
        source: applied.source,
        subject: applied.subject,
        partition_key: applied.partition_key,
        tenant_id: applied.tenant_id,
        swarm_id: applied.swarm_id,
        agent_id: applied.agent_id,
        action_key: applied.action_key,
        correlation_id: applied.correlation_id,
        causation_id: applied.id,
        sequence: 99,
        data: applied.data
      })

    Logger.info(
      "Dispatching retry #{retry_event.id} " <>
        "(action_key=#{retry_event.action_key}) → cell:#{cell_id}"
    )

    {:ok, status} = ColonyCell.dispatch(cell_id, retry_event)
    Logger.info("[retry] #{retry_event.id} → #{status} (expected :duplicate_action)")

    snapshot = ColonyCell.snapshot(cell_id)

    Logger.info(
      "Cell #{cell_id} after retry: #{snapshot.handled_events} events, " <>
        "actions=#{snapshot.applied_actions}, last_seq=#{snapshot.last_sequence}"
    )
  end

  def sample_events do
    correlation = "corr-#{System.unique_integer([:positive])}"
    incident = "incident-042"
    service = "checkout-svc"
    tenant = "tenant-acme"
    swarm = "incident-response"
    downstreams = ["orders-svc", "billing-svc", "shipping-svc"]

    deploy =
      Event.new(%{
        id: "evt-deploy-#{System.unique_integer([:positive])}",
        type: "deployment.completed",
        source: "cd.system",
        subject: service,
        partition_key: service,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "cd-runner",
        correlation_id: correlation,
        causation_id: correlation,
        sequence: 1,
        data: %{
          "service" => service,
          "version" => "v2.4.0",
          "schema_hash" => "9a1b4c2d"
        }
      })

    drift =
      Event.new(%{
        id: "evt-drift-#{System.unique_integer([:positive])}",
        type: "schema.drift.detected",
        source: "detector.schema",
        subject: service,
        partition_key: service,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "drift-detector-1",
        correlation_id: correlation,
        causation_id: deploy.id,
        sequence: 2,
        data: %{
          "service" => service,
          "field" => "order.total",
          "from" => "integer_cents",
          "to" => "decimal_dollars",
          "impacted_consumers" => downstreams
        }
      })

    opened =
      Event.new(%{
        id: "evt-opened-#{System.unique_integer([:positive])}",
        type: "incident.opened",
        source: "coordinator.triage",
        subject: incident,
        partition_key: incident,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "coordinator-1",
        correlation_id: correlation,
        causation_id: drift.id,
        sequence: 1,
        data: %{
          "incident_id" => incident,
          "trigger_event" => drift.id,
          "service" => service
        }
      })

    scan_requests =
      for {downstream, idx} <- Enum.with_index(downstreams) do
        Event.new(%{
          id: "evt-scan-req-#{downstream}-#{System.unique_integer([:positive])}",
          type: "impact.scan.requested",
          source: "coordinator.triage",
          subject: incident,
          partition_key: incident,
          tenant_id: tenant,
          swarm_id: swarm,
          agent_id: "coordinator-1",
          correlation_id: correlation,
          causation_id: opened.id,
          sequence: 2 + idx,
          data: %{"target_service" => downstream, "incident_id" => incident}
        })
      end

    scan_reports =
      for {{downstream, severity, endpoints}, idx} <-
            Enum.with_index([
              {"orders-svc", "high", 4},
              {"billing-svc", "medium", 2},
              {"shipping-svc", "low", 1}
            ]) do
        request = Enum.at(scan_requests, idx)

        Event.new(%{
          id: "evt-scan-rpt-#{downstream}-#{System.unique_integer([:positive])}",
          type: "impact.scan.reported",
          source: "scanner.#{downstream}",
          subject: incident,
          partition_key: incident,
          tenant_id: tenant,
          swarm_id: swarm,
          agent_id: "scanner-#{downstream}",
          correlation_id: correlation,
          causation_id: request.id,
          sequence: 5 + idx,
          data: %{
            "target_service" => downstream,
            "blast_radius" => severity,
            "affected_endpoints" => endpoints
          }
        })
      end

    triaged =
      Event.new(%{
        id: "evt-triaged-#{System.unique_integer([:positive])}",
        type: "incident.triaged",
        source: "coordinator.triage",
        subject: incident,
        partition_key: incident,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "coordinator-1",
        correlation_id: correlation,
        causation_id: List.last(scan_reports).id,
        sequence: 8,
        data: %{
          "severity" => "high",
          "total_affected_endpoints" => 7,
          "candidate_mitigations" => ["rollback", "schema_shim"]
        }
      })

    proposal_rollback =
      Event.new(%{
        id: "evt-prop-rollback-#{System.unique_integer([:positive])}",
        type: "mitigation.proposed",
        source: "specialist.rollback",
        subject: incident,
        partition_key: incident,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "specialist-rollback-1",
        correlation_id: correlation,
        causation_id: triaged.id,
        sequence: 9,
        data: %{
          "strategy" => "rollback",
          "target_version" => "v2.3.4",
          "estimated_recovery_seconds" => 90
        }
      })

    proposal_shim =
      Event.new(%{
        id: "evt-prop-shim-#{System.unique_integer([:positive])}",
        type: "mitigation.proposed",
        source: "specialist.schema_shim",
        subject: incident,
        partition_key: incident,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "specialist-shim-1",
        correlation_id: correlation,
        causation_id: triaged.id,
        sequence: 10,
        data: %{
          "strategy" => "schema_shim",
          "shim_layer" => "gateway",
          "estimated_recovery_seconds" => 300
        }
      })

    selected =
      Event.new(%{
        id: "evt-selected-#{System.unique_integer([:positive])}",
        type: "mitigation.selected",
        source: "coordinator.triage",
        subject: incident,
        partition_key: incident,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "coordinator-1",
        correlation_id: correlation,
        causation_id: proposal_rollback.id,
        sequence: 11,
        data: %{"chosen" => "rollback", "reason" => "fastest_recovery"}
      })

    applied =
      Event.new(%{
        id: "evt-applied-#{System.unique_integer([:positive])}",
        type: "mitigation.applied",
        source: "applier.rollout",
        subject: incident,
        partition_key: incident,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "applier-1",
        action_key: "apply:rollback:#{incident}",
        correlation_id: correlation,
        causation_id: selected.id,
        sequence: 12,
        data: %{
          "strategy" => "rollback",
          "target_version" => "v2.3.4",
          "result" => "ok"
        }
      })

    resolved =
      Event.new(%{
        id: "evt-resolved-#{System.unique_integer([:positive])}",
        type: "incident.resolved",
        source: "coordinator.triage",
        subject: incident,
        partition_key: incident,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "coordinator-1",
        correlation_id: correlation,
        causation_id: applied.id,
        sequence: 13,
        data: %{"outcome" => "mitigated", "duration_seconds" => 214}
      })

    [deploy, drift, opened] ++
      scan_requests ++
      scan_reports ++
      [triaged, proposal_rollback, proposal_shim, selected, applied, resolved]
  end
end
