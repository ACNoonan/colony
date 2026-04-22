defmodule ColonyDemo.Scenarios.BadConfigRollout do
  @moduledoc """
  Event fixtures and reasoning inputs for a **bad config rollout** reference
  scenario.

  A dynamic-config push to `checkout-svc` silently changes a rate-limit
  threshold and begins shedding valid requests on a subset of regions. The
  swarm opens one remediation episode, scans the blast radius, compares
  bounded options — `config_revert`, `feature_flag_disable`, and
  `quarantine` — selects one, applies it, verifies, and closes the episode.

  Event vocabulary follows `docs/adr/0001-canonical-control-loop-events.md`;
  OTel semantic conventions govern attribute names in `data`
  (`service.name`, `deployment.environment`, `cloud.region`).
  """

  @behaviour ColonyDemo.Scenario

  alias ColonyCore.Event

  @slug "bad_config_rollout"
  @title "Bad Config Rollout Response"
  @description "A dynamic-config push sheds valid traffic; swarm reverts, flags off, or quarantines."
  @default_episode "incident-config-013"
  @default_strategy "config_revert"
  @candidate_remediations ["config_revert", "feature_flag_disable", "quarantine"]
  @service "checkout-svc"
  @flag "aggressive_rate_limit_v2"
  @region "us-east-1"
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
    tenant = "tenant-acme"
    swarm = "incident-response"
    impacted = ["checkout-web", "orders-svc", "payments-svc"]

    rollout =
      Event.new(%{
        id: "evt-config-#{System.unique_integer([:positive])}",
        type: "change.detected",
        source: "cd.system",
        subject: @service,
        partition_key: @service,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "config-runner",
        correlation_id: correlation,
        causation_id: correlation,
        sequence: 1,
        data: %{
          "kind" => "config_rollout",
          "service.name" => @service,
          "deployment.environment" => @environment,
          "cloud.region" => @region,
          "config_key" => @flag,
          "config_value" => "40rps_per_tenant"
        }
      })

    opened =
      Event.new(%{
        id: "evt-opened-config-#{System.unique_integer([:positive])}",
        type: "episode.opened",
        source: "coordinator.triage",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "coordinator-1",
        correlation_id: correlation,
        causation_id: rollout.id,
        sequence: 1,
        data: %{
          "episode_id" => episode,
          "trigger_event" => rollout.id,
          "service.name" => @service,
          "deployment.environment" => @environment,
          "cloud.region" => @region,
          "signal" => "429_rate_above_baseline",
          "symptom" => "valid_traffic_shed_by_rate_limiter",
          "config_key" => @flag
        }
      })

    scan_requests =
      for {target, idx} <- Enum.with_index(impacted) do
        Event.new(%{
          id: "evt-config-scan-req-#{target}-#{System.unique_integer([:positive])}",
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
            "service.name" => target,
            "episode_id" => episode,
            "probe" => "rate_limit_regression"
          }
        })
      end

    scan_reports =
      for {{target, severity, endpoints}, idx} <-
            Enum.with_index([
              {"checkout-web", "high", 5},
              {"orders-svc", "high", 3},
              {"payments-svc", "medium", 2}
            ]) do
        request = Enum.at(scan_requests, idx)

        Event.new(%{
          id: "evt-config-scan-rpt-#{target}-#{System.unique_integer([:positive])}",
          type: "blast_radius.reported",
          source: "scanner.#{target}",
          subject: episode,
          partition_key: episode,
          tenant_id: tenant,
          swarm_id: swarm,
          agent_id: "scanner-#{target}",
          correlation_id: correlation,
          causation_id: request.id,
          sequence: 5 + idx,
          data: %{
            "service.name" => target,
            "blast_radius" => severity,
            "affected_endpoints" => endpoints
          }
        })
      end

    assessed =
      Event.new(%{
        id: "evt-assessed-config-#{System.unique_integer([:positive])}",
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
          "total_affected_endpoints" => 10,
          "candidate_remediations" => @candidate_remediations
        }
      })

    proposal_revert =
      Event.new(%{
        id: "evt-prop-revert-#{System.unique_integer([:positive])}",
        type: "remediation.proposed",
        source: "specialist.config_revert",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "specialist-config-1",
        correlation_id: correlation,
        causation_id: assessed.id,
        sequence: 9,
        data: %{
          "strategy" => "config_revert",
          "config_key" => @flag,
          "target_value" => "120rps_per_tenant",
          "estimated_recovery_seconds" => 30
        }
      })

    proposal_flag =
      Event.new(%{
        id: "evt-prop-flag-#{System.unique_integer([:positive])}",
        type: "remediation.proposed",
        source: "specialist.feature_flag",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "specialist-flag-1",
        correlation_id: correlation,
        causation_id: assessed.id,
        sequence: 10,
        data: %{
          "strategy" => "feature_flag_disable",
          "flag" => @flag,
          "estimated_recovery_seconds" => 60
        }
      })

    selected =
      Event.new(%{
        id: "evt-selected-config-#{System.unique_integer([:positive])}",
        type: "remediation.selected",
        source: "coordinator.triage",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "coordinator-1",
        correlation_id: correlation,
        causation_id: proposal_revert.id,
        sequence: 11,
        data: %{"chosen" => "config_revert", "reason" => "fastest_reversible_path"}
      })

    applied =
      Event.new(%{
        id: "evt-applied-config-#{System.unique_integer([:positive])}",
        type: "remediation.applied",
        source: "applier.rollout",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "applier-1",
        action_key: "apply:config_revert:#{episode}",
        correlation_id: correlation,
        causation_id: selected.id,
        sequence: 12,
        data: %{
          "strategy" => "config_revert",
          "config_key" => @flag,
          "target_value" => "120rps_per_tenant",
          "result" => "ok"
        }
      })

    verified =
      Event.new(%{
        id: "evt-verified-config-#{System.unique_integer([:positive])}",
        type: "remediation.verified",
        source: "applier.rollout",
        subject: episode,
        partition_key: episode,
        tenant_id: tenant,
        swarm_id: swarm,
        agent_id: "applier-1",
        action_key: "verify:config_revert:#{episode}",
        correlation_id: correlation,
        causation_id: applied.id,
        sequence: 13,
        data: %{
          "strategy" => "config_revert",
          "result" => "confirmed",
          "signal_cleared" => true
        }
      })

    closed =
      Event.new(%{
        id: "evt-closed-config-#{System.unique_integer([:positive])}",
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
        data: %{"outcome" => "mitigated", "duration_seconds" => 62}
      })

    [rollout, opened] ++
      scan_requests ++
      scan_reports ++
      [assessed, proposal_revert, proposal_flag, selected, applied, verified, closed]
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
      data:
        Map.merge(
          %{
            "strategy" => strategy,
            "estimated_recovery_seconds" => recovery_estimate(strategy)
          },
          strategy_payload(strategy)
        )
    })
  end

  def reason_trigger("specialist", episode, _strategy) do
    Event.new(%{
      id: "evt-assessed-config-#{System.unique_integer([:positive])}",
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
        "total_affected_endpoints" => 10,
        "candidate_remediations" => @candidate_remediations
      }
    })
  end

  def reason_trigger(role, _episode, _strategy) do
    raise ArgumentError, "bad_config_rollout has no canned trigger for role #{inspect(role)}"
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
          "candidate_remediations" => @candidate_remediations
        },
        %{
          "type" => "episode.opened",
          "service.name" => @service,
          "signal" => "429_rate_above_baseline",
          "config_key" => @flag
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
          "service.name" => @service,
          "signal" => "429_rate_above_baseline",
          "config_key" => @flag
        }
      ]
    }
  end

  def reason_projections(_role, _episode, _strategy), do: %{}

  defp recovery_estimate("config_revert"), do: 30
  defp recovery_estimate("feature_flag_disable"), do: 60
  defp recovery_estimate("quarantine"), do: 120
  defp recovery_estimate(_), do: 120

  defp strategy_payload("config_revert"),
    do: %{"config_key" => @flag, "target_value" => "120rps_per_tenant"}

  defp strategy_payload("feature_flag_disable"), do: %{"flag" => @flag}
  defp strategy_payload("quarantine"), do: %{"cloud.region" => @region}
  defp strategy_payload(_), do: %{}

  defp alternate_strategy("config_revert"), do: "feature_flag_disable"
  defp alternate_strategy("feature_flag_disable"), do: "config_revert"
  defp alternate_strategy("quarantine"), do: "config_revert"
  defp alternate_strategy(_), do: "config_revert"
end
