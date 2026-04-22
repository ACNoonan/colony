defmodule ColonyDemo.Scenarios.CanaryRegression do
  @moduledoc """
  Event fixtures and reasoning inputs for a **canary regression** reference
  scenario.

  A small rollout of `checkout-svc` degrades customer-facing behavior after a
  deploy. The swarm opens one remediation episode, scans impacted surfaces,
  compares bounded remediation options, chooses one, applies it, verifies,
  and closes the loop.

  Event vocabulary follows `docs/adr/0001-canonical-control-loop-events.md`;
  OTel semantic conventions (`service.name`, `deployment.environment`,
  `deployment.revision`, `cloud.region`) govern attribute names in `data`.
  """

  @behaviour ColonyDemo.Scenario

  alias ColonyCore.Event

  @slug "canary_regression"
  @title "Canary Regression Response"
  @description "A 5% canary degrades customer paths; swarm compares pause vs. rollback vs. shift."
  @default_episode "incident-canary-007"
  @default_strategy "pause_canary"
  @candidate_remediations ["pause_canary", "rollback", "traffic_shift"]
  @environment "prod"
  @region "us-east-1"

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
    downstreams = ["checkout-web", "payments-svc", "api-gateway"]

    deploy =
      Event.new(%{
        id: "evt-deploy-canary-#{System.unique_integer([:positive])}",
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
          "deployment.revision" => "v2.5.0",
          "deployment.strategy" => "canary",
          "canary_percent" => 5,
          "cloud.region" => @region
        }
      })

    opened =
      Event.new(%{
        id: "evt-opened-canary-#{System.unique_integer([:positive])}",
        type: "episode.opened",
        source: "coordinator.triage",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "coordinator-1",
        correlation_id: correlation,
        causation_id: deploy.id,
        sequence: 1,
        data: %{
          "episode_id" => episode,
          "trigger_event" => deploy.id,
          "service.name" => service,
          "deployment.environment" => @environment,
          "signal" => "checkout_latency_p95_regressed",
          "symptom" => "canary_error_rate_above_threshold"
        }
      })

    scan_requests =
      for {downstream, idx} <- Enum.with_index(downstreams) do
        Event.new(%{
          id: "evt-canary-scan-req-#{downstream}-#{System.unique_integer([:positive])}",
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
            "episode_id" => episode,
            "probe" => "canary_regression"
          }
        })
      end

    scan_reports =
      for {{downstream, severity, endpoints}, idx} <-
            Enum.with_index([
              {"checkout-web", "high", 6},
              {"payments-svc", "medium", 3},
              {"api-gateway", "medium", 2}
            ]) do
        request = Enum.at(scan_requests, idx)

        Event.new(%{
          id: "evt-canary-scan-rpt-#{downstream}-#{System.unique_integer([:positive])}",
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
        id: "evt-assessed-canary-#{System.unique_integer([:positive])}",
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
          "total_affected_endpoints" => 11,
          "candidate_remediations" => @candidate_remediations
        }
      })

    proposal_pause =
      Event.new(%{
        id: "evt-prop-pause-canary-#{System.unique_integer([:positive])}",
        type: "remediation.proposed",
        source: "specialist.canary",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "specialist-canary-1",
        correlation_id: correlation,
        causation_id: assessed.id,
        sequence: 9,
        data: %{
          "strategy" => "pause_canary",
          "canary_percent" => 5,
          "estimated_recovery_seconds" => 45
        }
      })

    proposal_rollback =
      Event.new(%{
        id: "evt-prop-canary-rollback-#{System.unique_integer([:positive])}",
        type: "remediation.proposed",
        source: "specialist.rollback",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "specialist-rollback-1",
        correlation_id: correlation,
        causation_id: assessed.id,
        sequence: 10,
        data: %{
          "strategy" => "rollback",
          "target_version" => "v2.4.8",
          "estimated_recovery_seconds" => 120
        }
      })

    selected =
      Event.new(%{
        id: "evt-selected-canary-#{System.unique_integer([:positive])}",
        type: "remediation.selected",
        source: "coordinator.triage",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "coordinator-1",
        correlation_id: correlation,
        causation_id: proposal_pause.id,
        sequence: 11,
        data: %{"chosen" => "pause_canary", "reason" => "lowest_blast_radius"}
      })

    applied =
      Event.new(%{
        id: "evt-applied-canary-#{System.unique_integer([:positive])}",
        type: "remediation.applied",
        source: "applier.rollout",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "applier-1",
        action_key: "apply:pause_canary:#{episode}",
        correlation_id: correlation,
        causation_id: selected.id,
        sequence: 12,
        data: %{
          "strategy" => "pause_canary",
          "canary_percent" => 5,
          "result" => "ok"
        }
      })

    verified =
      Event.new(%{
        id: "evt-verified-canary-#{System.unique_integer([:positive])}",
        type: "remediation.verified",
        source: "applier.rollout",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "applier-1",
        action_key: "verify:pause_canary:#{episode}",
        correlation_id: correlation,
        causation_id: applied.id,
        sequence: 13,
        data: %{
          "strategy" => "pause_canary",
          "result" => "confirmed",
          "signal_cleared" => true
        }
      })

    closed =
      Event.new(%{
        id: "evt-closed-canary-#{System.unique_integer([:positive])}",
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
        data: %{"outcome" => "mitigated", "duration_seconds" => 96}
      })

    [deploy, opened] ++
      scan_requests ++
      scan_reports ++
      [assessed, proposal_pause, proposal_rollback, selected, applied, verified, closed]
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
        "canary_percent" => 5,
        "estimated_recovery_seconds" => recovery_estimate(strategy)
      }
    })
  end

  def reason_trigger("specialist", episode, _strategy) do
    Event.new(%{
      id: "evt-assessed-canary-#{System.unique_integer([:positive])}",
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
        "total_affected_endpoints" => 11,
        "candidate_remediations" => @candidate_remediations
      }
    })
  end

  def reason_trigger(role, _episode, _strategy) do
    raise ArgumentError, "canary_regression has no canned trigger for role #{inspect(role)}"
  end

  @impl true
  def reason_projections("coordinator", episode, strategy) do
    alternate = alternate_strategy(strategy)

    %{
      episode => [
        %{
          "type" => "remediation.proposed",
          "strategy" => strategy,
          "estimated_recovery_seconds" => recovery_estimate(strategy)
        },
        %{
          "type" => "remediation.proposed",
          "strategy" => alternate,
          "estimated_recovery_seconds" => recovery_estimate(alternate)
        },
        %{
          "type" => "blast_radius.assessed",
          "severity" => "high",
          "candidate_remediations" => [strategy, alternate, "traffic_shift"]
        },
        %{
          "type" => "episode.opened",
          "service.name" => "checkout-svc",
          "signal" => "checkout_latency_p95_regressed"
        }
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
        %{
          "type" => "episode.opened",
          "service.name" => "checkout-svc",
          "signal" => "checkout_latency_p95_regressed"
        }
      ]
    }
  end

  def reason_projections(_role, _episode, _strategy), do: %{}

  defp recovery_estimate("pause_canary"), do: 45
  defp recovery_estimate(_), do: 120

  defp alternate_strategy("pause_canary"), do: "rollback"
  defp alternate_strategy("rollback"), do: "pause_canary"
  defp alternate_strategy(_), do: "rollback"
end
