defmodule ColonyDemo.Scenarios.ChangeFailure do
  @moduledoc """
  Event fixtures and reasoning inputs for the **change-failure response**
  reference scenario (README capability ladder step 1).

  Deploy + schema drift → blast-radius scans → assessment → remediation
  proposals → selection → apply → verify → episode close.

  Event vocabulary follows `docs/adr/0001-canonical-control-loop-events.md`;
  attribute names inside `data` follow OpenTelemetry semantic conventions
  where applicable (`service.name`, `deployment.environment`,
  `deployment.revision`, `schema.field`).
  """

  @behaviour ColonyDemo.Scenario

  alias ColonyCore.Event

  @slug "change_failure"
  @title "Change-Failure Response"
  @description "Deploy + schema drift breaks downstream consumers; swarm picks a bounded fix."
  @default_episode "incident-042"
  @default_strategy "rollback"
  @candidate_remediations ["rollback", "schema_shim"]
  @environment "prod"

  @impl true
  def slug, do: @slug

  @impl true
  def title, do: @title

  @impl true
  def description, do: @description

  @impl true
  def default_episode_subject, do: @default_episode

  @impl true
  def default_strategy, do: @default_strategy

  @impl true
  def candidate_remediations, do: @candidate_remediations

  @impl true
  def events do
    correlation = "corr-#{System.unique_integer([:positive])}"
    episode = @default_episode
    service = "checkout-svc"
    tenant = "tenant-acme"
    swarm = "incident-response"
    downstreams = ["orders-svc", "billing-svc", "shipping-svc"]

    deploy =
      Event.new(%{
        id: "evt-deploy-#{System.unique_integer([:positive])}",
        type: "change.detected",
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
          "kind" => "deployment",
          "service.name" => service,
          "deployment.environment" => @environment,
          "deployment.revision" => "v2.4.0",
          "schema_hash" => "9a1b4c2d"
        }
      })

    drift =
      Event.new(%{
        id: "evt-drift-#{System.unique_integer([:positive])}",
        type: "change.detected",
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
          "kind" => "schema_drift",
          "service.name" => service,
          "deployment.environment" => @environment,
          "schema.field" => "order.total",
          "from" => "integer_cents",
          "to" => "decimal_dollars",
          "impacted_consumers" => downstreams
        }
      })

    opened =
      Event.new(%{
        id: "evt-opened-#{System.unique_integer([:positive])}",
        type: "episode.opened",
        source: "coordinator.triage",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "coordinator-1",
        correlation_id: correlation,
        causation_id: drift.id,
        sequence: 1,
        data: %{
          "episode_id" => episode,
          "trigger_event" => drift.id,
          "service.name" => service,
          "deployment.environment" => @environment
        }
      })

    scan_requests =
      for {downstream, idx} <- Enum.with_index(downstreams) do
        Event.new(%{
          id: "evt-scan-req-#{downstream}-#{System.unique_integer([:positive])}",
          type: "blast_radius.requested",
          source: "coordinator.triage",
          subject: episode,
          partition_key: episode,
          tenant_id: tenant,
          swarm_id: swarm,
          agent_id: "coordinator-1",
          correlation_id: correlation,
          causation_id: opened.id,
          sequence: 2 + idx,
          data: %{
            "service.name" => downstream,
            "episode_id" => episode
          }
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
          type: "blast_radius.reported",
          source: "scanner.#{downstream}",
          subject: episode,
          partition_key: episode,
          tenant_id: tenant,
          swarm_id: swarm,
          agent_id: "scanner-#{downstream}",
          correlation_id: correlation,
          causation_id: request.id,
          sequence: 5 + idx,
          data: %{
            "service.name" => downstream,
            "blast_radius" => severity,
            "affected_endpoints" => endpoints
          }
        })
      end

    assessed =
      Event.new(%{
        id: "evt-assessed-#{System.unique_integer([:positive])}",
        type: "blast_radius.assessed",
        source: "coordinator.triage",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "coordinator-1",
        correlation_id: correlation,
        causation_id: List.last(scan_reports).id,
        sequence: 8,
        data: %{
          "severity" => "high",
          "total_affected_endpoints" => 7,
          "candidate_remediations" => @candidate_remediations
        }
      })

    proposal_rollback =
      Event.new(%{
        id: "evt-prop-rollback-#{System.unique_integer([:positive])}",
        type: "remediation.proposed",
        source: "specialist.rollback",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "specialist-rollback-1",
        correlation_id: correlation,
        causation_id: assessed.id,
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
        type: "remediation.proposed",
        source: "specialist.schema_shim",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "specialist-shim-1",
        correlation_id: correlation,
        causation_id: assessed.id,
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
        type: "remediation.selected",
        source: "coordinator.triage",
        subject: episode,
        partition_key: episode,
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
        type: "remediation.applied",
        source: "applier.rollout",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "applier-1",
        action_key: "apply:rollback:#{episode}",
        correlation_id: correlation,
        causation_id: selected.id,
        sequence: 12,
        data: %{
          "strategy" => "rollback",
          "target_version" => "v2.3.4",
          "result" => "ok"
        }
      })

    verified =
      Event.new(%{
        id: "evt-verified-#{System.unique_integer([:positive])}",
        type: "remediation.verified",
        source: "applier.rollout",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "applier-1",
        action_key: "verify:rollback:#{episode}",
        correlation_id: correlation,
        causation_id: applied.id,
        sequence: 13,
        data: %{
          "strategy" => "rollback",
          "result" => "confirmed",
          "signal_cleared" => true
        }
      })

    closed =
      Event.new(%{
        id: "evt-closed-#{System.unique_integer([:positive])}",
        type: "episode.closed",
        source: "coordinator.triage",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "coordinator-1",
        correlation_id: correlation,
        causation_id: verified.id,
        sequence: 14,
        data: %{"outcome" => "mitigated", "duration_seconds" => 214}
      })

    [deploy, drift, opened] ++
      scan_requests ++
      scan_reports ++
      [assessed, proposal_rollback, proposal_shim, selected, applied, verified, closed]
  end

  @impl true
  def reason_trigger("coordinator", episode, strategy) do
    Event.new(%{
      id: "evt-proposed-#{strategy}-#{System.unique_integer([:positive])}",
      type: "remediation.proposed",
      source: "specialist.#{strategy}",
      subject: episode,
      partition_key: episode,
      correlation_id: "corr-#{episode}",
      causation_id: "evt-assessed-#{episode}",
      tenant_id: "tenant-acme",
      swarm_id: "incident-response",
      sequence: 9,
      data: %{
        "strategy" => strategy,
        "target_version" => "v2.3.4",
        "estimated_recovery_seconds" => 90
      }
    })
  end

  def reason_trigger("specialist", episode, _strategy) do
    Event.new(%{
      id: "evt-assessed-#{System.unique_integer([:positive])}",
      type: "blast_radius.assessed",
      source: "coordinator.triage",
      subject: episode,
      partition_key: episode,
      correlation_id: "corr-#{episode}",
      causation_id: "evt-opened-#{episode}",
      tenant_id: "tenant-acme",
      swarm_id: "incident-response",
      sequence: 8,
      data: %{
        "severity" => "high",
        "total_affected_endpoints" => 7,
        "candidate_remediations" => @candidate_remediations
      }
    })
  end

  def reason_trigger(role, _episode, _strategy) do
    raise ArgumentError, "change_failure has no canned trigger for role #{inspect(role)}"
  end

  @impl true
  def reason_projections("coordinator", episode, strategy) do
    %{
      episode => [
        %{
          "type" => "remediation.proposed",
          "strategy" => strategy,
          "estimated_recovery_seconds" => 90
        },
        %{
          "type" => "remediation.proposed",
          "strategy" => "schema_shim",
          "estimated_recovery_seconds" => 300
        },
        %{
          "type" => "blast_radius.assessed",
          "severity" => "high",
          "candidate_remediations" => [strategy, "schema_shim"]
        },
        %{"type" => "episode.opened", "service.name" => "checkout-svc"}
      ]
    }
  end

  def reason_projections("specialist", episode, _strategy) do
    %{
      episode => [
        %{
          "type" => "blast_radius.assessed",
          "severity" => "high",
          "candidate_remediations" => @candidate_remediations
        },
        %{"type" => "episode.opened", "service.name" => "checkout-svc"}
      ]
    }
  end

  def reason_projections(_role, _episode, _strategy), do: %{}
end
