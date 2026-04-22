# Colony Roadmap

This is the long-term support surface Colony is aiming at, the phased path to
get there, and the principles that keep the runtime coherent as it widens.

For the product thesis and the current implementation status, see
[`README.md`](README.md). For production-readiness gaps in what's already
shipped, see [`FINDINGS.md`](FINDINGS.md). For load-bearing architectural
decisions, see [`docs/adr/`](docs/adr/).

---

## North Star

Colony is a durable coordination runtime for **self-healing infrastructure**.

The goal is a control loop that can:

1. **ingest** signals from infrastructure, delivery, and observability systems
2. **gather context** from control planes and observability backends
3. **assess** blast radius and likely cause
4. **propose** bounded remediations
5. **apply** approved actions safely and reversibly
6. **verify** outcomes
7. **preserve** replayable evidence and operator audit trails

The roadmap is organized around *what systems Colony can read from and act on*,
not around any single scripted demo.

---

## The Canonical Control Loop

Colony has one control loop. Every supported scenario is a specialization of
the same loop, not a new system. This is the single most important design
choice in the project.

```
  signal        →  episode    →  context        →  remediation          →  verification
  (external)       (opened)      (assessed)        (proposed/selected      (verified,
                                                    applied)                 episode closed)
```

Each step is expressed in a canonical event vocabulary that is intentionally
*smaller* than any single vendor's event model. Adapters translate vendor
signals into this vocabulary at the runtime's edge; scenarios and policies
compose on top of it.

The canonical vocabulary is defined in
[ADR-0001](docs/adr/0001-canonical-control-loop-events.md). The structural
adapter seam is defined in [ADR-0002](docs/adr/0002-adapter-seam.md).
Colony's relationship to OpenTelemetry — specifically, that OTel governs
attribute naming inside `data` payloads while control-loop event types
remain Colony's — is defined in
[ADR-0004](docs/adr/0004-opentelemetry-relationship.md).

---

## Integration Surfaces

Colony's long-term support surface is organized as seven integration families.
The roadmap below schedules which surfaces become first-class in which phase —
but the architecture accommodates all seven from day one.

### 1. Signal sources

Systems that tell Colony something may be wrong.

- deployment events, rollout status changes
- SLO/burn-rate alerts, error spikes
- workload lifecycle failures (pod/task/container)
- autoscaling anomalies, capacity saturation
- cost spikes, infrastructure health changes
- security findings, queue backlog growth
- data-plane saturation (database, cache)

Concrete integrations Colony eventually supports:

- Delivery: GitHub Actions, GitLab CI, ArgoCD, Flux, AWS CodePipeline / CodeDeploy
- Orchestrators: Kubernetes events, ECS service events, EventBridge
- Alerting: Prometheus Alertmanager, Grafana Alerting, CloudWatch alarms
- Error tracking: Sentry
- APM / metrics vendors: Datadog, and other OpenTelemetry-compatible backends

### 2. Context sources

Systems Colony queries to understand what's actually happening.

- metrics, logs, traces
- service topology, rollout state, desired-vs-actual config
- feature flag state, recent deploy history
- ownership / service catalog, runbook documentation
- cloud resource state

Concrete integrations:

- Observability: Prometheus, Grafana, Loki, Tempo, OpenTelemetry backends, CloudWatch Logs / Metrics
- Control planes: Kubernetes API, ECS API, ArgoCD API
- Infrastructure state: Terraform state / plan outputs
- Service catalog: Backstage, GitHub repos / CODEOWNERS / runbook docs

### 3. Action targets

Systems Colony can safely influence.

- pause rollout, rollback deploy, restart workload
- scale service, shift traffic, drain workload
- disable feature flag, quarantine unhealthy target
- trigger runbook, suppress noisy alert (bounded window)
- open/update incident, notify humans, request approval
- rotate config or secret references
- perform safe cloud scaling actions

Concrete targets:

- Orchestrator APIs: Kubernetes, ECS, Argo Rollouts, CodeDeploy
- Traffic control: ALB / target groups / weighted routing, service mesh controllers
- Feature flags: LaunchDarkly, OpenFeature, AWS AppConfig
- Runbook execution: SSM Automation, Step Functions, runbook runners
- Human-ops: PagerDuty, Discord, Slack, Jira, Linear

### 4. Platform environments

Runtime environments Colony must understand in depth.

- Kubernetes
- ECS
- EC2 / VM workloads
- serverless edges (where actionable)
- managed data planes as dependencies

### 5. Governance and policy

Required for self-healing to be trusted.

- approval policies, action allowlists
- environment-specific limits
- reversible vs irreversible action classes
- confidence thresholds, maintenance windows
- human escalation paths
- audit evidence retention

Enforcement points: an internal policy engine in Colony, optionally
OPA/Rego later; approval flow via Discord / Slack / PagerDuty / GitHub; role-based
action scopes.

### 6. Operator surfaces

How humans see and trust what the swarm is doing.

- live timeline, episode summary, blast-radius report
- proposed actions with rationale
- action approval / rejection UI
- replay evidence
- current cell state, gate violations, drift and policy visibility
- remediation outcome verification

### 7. Learning and optimization

Later-stage but load-bearing for the full vision.

- post-incident replay analysis
- runbook effectiveness tracking
- recurring incident clustering
- action success-rate tracking
- cost-aware remediation preferences
- policy tuning
- scenario regression evaluations

---

## Reference Lanes

Colony commits to two orchestrator lanes, implemented to parity so the
canonical event vocabulary cannot leak orchestrator assumptions. See
[ADR-0003](docs/adr/0003-reference-lanes.md).

### Lane A — Kubernetes

The first reference lane. Runs entirely locally (kind / minikube / k3d)
against a free, open stack.

- **Signals:** Kubernetes events, rollout status, Alertmanager, Grafana Alerting
- **Context:** Prometheus, Loki, Kubernetes API, optionally Tempo
- **Actions:** rollout pause / rollback / restart / scale / quarantine
- **Progressive delivery:** Argo Rollouts (later)

Representative scenarios: deploy regressions, bad config rollouts, crashloops,
readiness failures, canary regressions, saturation events.

### Lane B — ECS

The second reference lane. Validates that nothing in the runtime depends on
Kubernetes-specific semantics.

- **Signals:** ECS service events, EventBridge, CloudWatch alarms, deployment state changes
- **Context:** ECS API, CloudWatch, Prometheus / Grafana / Loki where deployed
- **Actions:** service update, task replacement, rollback, scale, traffic shift
- **Progressive delivery:** CodeDeploy blue/green, ALB weighted traffic (later)

Parity requirement: every canonical scenario that works on Lane A must have
an equivalent implementation on Lane B, exercising the same canonical events.

---

## Observability Family

Observability is treated as its own first-class family, independent of
orchestrator lane. The stack:

- **Metrics:** Prometheus (both lanes), CloudWatch Metrics (Lane B)
- **Logs:** Loki (both lanes), CloudWatch Logs (Lane B)
- **Traces:** Tempo / OpenTelemetry (later, both lanes)
- **Dashboards / alerting:** Grafana (both lanes), native Grafana Alerting
- **Additional vendor backends:** Datadog and other OpenTelemetry-compatible tools
  land as input adapters later

### OpenTelemetry posture

OpenTelemetry is Colony's observability lingua franca, with a sharply
scoped role:

- **Attribute names** inside canonical event `data` payloads follow OTel
  semantic conventions (`service.name`, `k8s.deployment.name`,
  `cloud.region`, etc.) from day one. This is a first-wave commitment and
  costs ~nothing to adopt.
- **OTLP ingestion** at input adapters is the preferred path for any
  signal source that speaks OTLP natively. Scheduled for second wave.
- **Self-observability** — Colony's own activity optionally emitted as
  OTel spans/events so remediation work shows up in the same
  Grafana/Tempo dashboards operators already run. Scheduled for second
  wave.
- **OTel is not Colony's control-loop vocabulary.** Event *types*
  (`change.detected`, `remediation.proposed`, etc.) remain governed by
  ADR-0001. OTel governs the inside of `data`, not the event type.

See [ADR-0004](docs/adr/0004-opentelemetry-relationship.md) for the full
reasoning, including how OTel trace context coexists with (rather than
replaces) Colony's `correlation_id` / `causation_id` causation chain.

---

## Capability Phases

Each phase widens the control loop. The phase number indicates what Colony can
*reliably* do, not what it can demo.

### Phase 1 — Incident coordination

> **Status:** in progress. Reference scenarios shipped; canonical-event
> migration and signal ingestion from real providers are the open work.

Goal: prove the runtime can coordinate diagnosis and resolution planning
across real operational signals.

- **Scenarios:** deploy / change regressions, schema drift / compatibility
  breakage, canary regressions, bad config rollouts, dependency regressions.
- **Signals:** deploy events, Prometheus / Grafana alerts, Loki logs,
  Kubernetes or ECS status, optional Sentry.
- **Actions:** recommend only (or simulated apply).
- **Proves:** signal ingestion, blast-radius assessment, fan-out/fan-in
  coordination, replay safety, action idempotency, operator explainability.

**Signal sourcing policy for Phase 1:** start with *simulated real* signals
(replay fixtures that match the exact schema and shape of real provider
payloads — Kubernetes event objects, Alertmanager webhooks, Loki query
responses). Move to *live* ingestion against a local Kubernetes cluster
before the phase is considered complete.

### Phase 2 — Assisted remediation

Goal: move from diagnosis into bounded action.

- **Scenarios:** rollback, pause canary, restart workload, traffic shift,
  quarantine, feature-flag disable, runbook execution.
- **Integrations:** orchestrator APIs, rollout / deploy APIs, feature flag
  systems, runbook executors, human-ops channels.
- **Proves:** action proposals are operationally meaningful, approval
  boundaries hold, actions are reversible where possible, replay does not
  double-apply side effects.

**First real action targets:** Discord (human notification / approval prompt)
and Linear (work tracking). Orchestrator actions follow once approval flows
are exercised.

### Phase 3 — Platform remediation

Goal: support orchestrator-native healing loops.

- **Scenarios:** crashloop recovery, stuck rollout remediation,
  saturation-triggered scaling, dependency failover, unhealthy target
  draining, autoscaling intervention, capacity rebalance.
- **Integrations:** Kubernetes, ECS, traffic control plane, service mesh /
  ALB / deployment controllers, cloud APIs.
- **Proves:** Colony operates inside real platform control planes; it is no
  longer only incident triage.

### Phase 4 — Cross-system coordination

Goal: coordinate across infrastructure, delivery, observability, and
human-ops systems.

- **Scenarios:** deploy rollback + traffic shift + alert suppression +
  notification chains; multi-service blast-radius handling; service-ownership-aware
  escalation; runbook + approval + action chains.
- **Integrations:** Backstage / service catalog, PagerDuty, Discord / Slack,
  issue trackers, runbook systems.
- **Proves:** Colony is a coordination runtime, not an alert bot.

### Phase 5 — Optimization and guarded autonomy

Goal: widen from break/fix into continuous operational improvement.

- **Scenarios:** cost spikes, under/overprovisioning, wasteful workloads,
  recurring noisy failures, policy-guided tuning suggestions.
- **Integrations:** cloud billing / cost APIs, scaling policies, infrastructure
  metadata, historical replay data.
- **Proves:** the system shapes infrastructure health over time, not only
  recovers from incidents.

### Phase 6 — Mature self-healing

Goal: support tightly bounded autonomous loops in production.

- **Scenarios:** low-risk approved actions auto-executed; confidence-scored
  escalation; policy-driven safe modes; environment-specific autonomy limits.
- **Proves:** real self-healing, not workflow automation theater.

---

## Priority Matrix

### First-class early targets

- Orchestrators: Kubernetes, ECS
- Observability: Prometheus, Grafana, Loki, Alertmanager, CloudWatch
- **OTel semantic conventions for all `data` attribute naming** (see ADR-0004)
- Delivery: GitHub Actions, GitLab, ArgoCD
- Human-ops: Discord, Slack, PagerDuty, Linear
- Actions: rollout restart / rollback / pause canary / scale / traffic shift

### Second wave

- **OTLP-native ingestion** at input adapters (preferred path for any
  OTLP-speaking source)
- **OTel self-observability**: Colony's own activity emitted as OTel
  spans / events for existing Grafana/Tempo dashboards
- Tracing context: Tempo / OpenTelemetry as a context source for
  remediation decisions
- Feature flags: LaunchDarkly, OpenFeature, AppConfig
- Delivery: CodeDeploy / CodePipeline, Argo Rollouts (progressive delivery)
- Error tracking: Sentry
- Service catalog: Backstage
- Runbook engines
- Infrastructure change context: Terraform state / plan

### Later wave

- Cost platforms
- Security tooling (signal side)
- EC2 / VM remediation
- Database / cache safe-action surfaces
- Multi-cloud generalized abstractions
- Advanced service-mesh remediation

---

## Guiding Principles

These are the non-negotiables. Every roadmap decision is checked against them.

1. **Standardize the control loop, not vendor specifics.** Adapters live at
   the edges. Canonical events live in the middle. Scenarios and policies
   compose on top. Bounded action interfaces at the end.
2. **Two-lane parity.** No runtime feature is done if it works only on one
   orchestrator lane.
3. **Bounded autonomy before broad autonomy.** The progression is
   `understand → recommend → assist → auto-remediate within policy`.
4. **Durable events are part of the product.** Kafka is not infrastructure
   cosplay — it is how replay, causal chains, auditability, and partitioned
   coordination become tractable.
5. **Reversibility is a first-class action property.** Actions are classified
   by reversibility; policy limits escalate for irreversible ones.
6. **Evidence is not a side effect.** Every episode produces a reconstructible
   timeline, ownership trail, and policy-violation record, by default.
7. **Ubiquitous language lives in the manifest and the canonical event
   vocabulary.** Role prompts, scenarios, and adapters all speak the same
   names for the same things.
8. **OpenTelemetry where the industry already agreed; Colony where it
   hasn't.** OTel governs attribute naming and observability wire formats;
   Colony governs control-loop event types and episode-scoped causation.

---

## Current Status (2026-04-22)

- Phase 1 reference scenarios shipping: `change_failure`, `canary_regression`,
  `bad_config_rollout`.
- Canonical event vocabulary defined but not yet migrated in code
  ([ADR-0001](docs/adr/0001-canonical-control-loop-events.md) has the full
  mapping from the current scenario-flavored events).
- Adapter seam declared, not yet implemented
  ([ADR-0002](docs/adr/0002-adapter-seam.md)).
- OpenTelemetry posture declared; semantic-convention adoption in `data`
  payloads lands with the ADR-0001 migration
  ([ADR-0004](docs/adr/0004-opentelemetry-relationship.md)).
- Lane A (Kubernetes) bring-up is the next focus; Lane B (ECS) follows.
- First real action targets: Discord and Linear (Phase 2).
- See [`FINDINGS.md`](FINDINGS.md) for runtime-hardening gaps.
