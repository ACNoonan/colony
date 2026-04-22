# ADR-0003: Kubernetes and ECS as orchestrator-parity reference lanes

- **Status:** Accepted — 2026-04-22
- **Depends on:** [ADR-0001](0001-canonical-control-loop-events.md),
  [ADR-0002](0002-adapter-seam.md)

## Context

Colony aims to support self-healing infrastructure across multiple
orchestration platforms. If Colony is validated against only one
orchestrator, the canonical event vocabulary risks quietly absorbing that
orchestrator's assumptions: pod semantics, rollout object shapes, event
envelopes, reconciliation-loop framing. The runtime would compile, the
scenarios would work, and the first time a second orchestrator was
integrated the real coupling would surface.

The cheapest insurance against that failure mode is to commit to a second
orchestrator early — as a design constraint, not as a later milestone.

## Decision

Colony commits to two reference orchestrator lanes, implemented to parity
across the canonical event vocabulary.

### Lane A — Kubernetes

The first lane and the primary proving ground through Phase 1 and Phase 3.

- **Environment:** local Kubernetes (kind / minikube / k3d) is the default
  development target. The lane must run end-to-end on a developer laptop
  with no cloud dependencies.
- **Signal sources:** Kubernetes API events and rollout status;
  Prometheus Alertmanager; Grafana Alerting.
- **Context sources:** Prometheus, Loki, Kubernetes API; Tempo later.
- **Action targets:** rollout pause / rollback / restart / scale /
  quarantine via the Kubernetes API; Argo Rollouts in a later wave.

### Lane B — ECS

The second lane, brought up after Lane A's canonical-event shape has
stabilized.

- **Environment:** AWS ECS with Fargate or EC2 capacity providers.
- **Signal sources:** ECS service events, EventBridge, CloudWatch alarms,
  deployment state changes.
- **Context sources:** ECS API, CloudWatch Logs and Metrics; Prometheus /
  Grafana / Loki where deployed.
- **Action targets:** service update, task replacement, rollback, scale,
  traffic shift. Later: CodeDeploy blue/green and ALB weighted traffic.

### Parity rule

A scenario is not considered Phase-complete until it is implemented for
both lanes through adapters only. Any scenario that works on one lane but
resists implementation on the other is evidence that orchestrator
semantics have leaked into the canonical vocabulary — and that is an
ADR-0001 violation to be fixed upstream of the scenario.

### Observability family

The observability family — Prometheus, Grafana, Loki, Tempo/OpenTelemetry,
and CloudWatch on Lane B — is treated as independent of the orchestrator
lane. An input adapter for Prometheus is reusable across both lanes; the
lane distinction lives in the orchestrator adapters, not the observability
adapters.

## Alternatives considered

1. **Kubernetes-only for the first year.** Rejected: by the time a second
   orchestrator is introduced, scenarios, role prompts, and gate logic will
   have absorbed Kubernetes assumptions, and the second-lane cost will be
   much higher than the cost of committing to parity now.
2. **ECS-first because of the author's experience.** Rejected for the
   public roadmap: Kubernetes has a free, open, locally-runnable
   development loop that every contributor can reproduce. ECS requires
   AWS credentials and running cost. The lane order serves the project,
   not individual experience.
3. **Abstract orchestrator interface in Elixir.** Rejected as premature.
   The canonical event vocabulary plus the adapter seam already abstract
   orchestrator differences at the event layer, which is the only place
   that matters. An in-process interface would be speculative until a
   third orchestrator arrives.

## Consequences

### Positive

- A concrete forcing function for canonical-event purity: if Lane B cannot
  express what Lane A expresses, the canonical vocabulary is wrong.
- The OSS contributor story is strong: clone the repo, start a local
  Kubernetes, run a scenario, inspect the event timeline. No cloud bill
  required.
- Lane B introduces AWS-specific surfaces (EventBridge, CloudWatch) that
  would otherwise be deferred indefinitely.

### Negative / accepted

- Every scenario costs more to ship in full: two adapters, two sets of
  integration tests.
- Lane B depends on AWS credentials for live tests. Simulated-signal tests
  remain fully local.
- Some vendor features (e.g. Argo Rollouts) have no direct Lane B analog;
  the parity rule applies to *canonical capability* (progressive
  delivery), not to feature-for-feature equivalence.

### Forward-looking

- Phase 1 lands on Lane A first; Lane B bring-up begins once the canonical
  vocabulary migration from ADR-0001 is complete and one Phase 1 scenario
  runs end-to-end on a local Kubernetes cluster.
- A future ADR will cover how the observability family (Prometheus stack)
  is deployed inside Lane A's local-dev environment (in-cluster vs
  sidecar) once that decision becomes load-bearing.
