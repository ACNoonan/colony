# ADR-0001: Canonical control-loop event vocabulary

- **Status:** Accepted — 2026-04-22
- **Scope:** Runtime-wide. Affects every cell, scenario, adapter, and
  operator tool.

## Context

The Phase 1 reference scenarios use a scenario-flavored event vocabulary:
`schema.drift.detected`, `incident.opened`, `impact.scan.requested`,
`mitigation.proposed`, and so on. The names are readable and the scenarios
work, but the vocabulary has two structural problems:

1. **It encodes the first scenario's framing into the runtime.** New
   scenarios either inherit incident-shaped naming that doesn't quite fit
   (a cost spike is not an "incident" in the same sense) or invent parallel
   vocabularies, leading to incoherent event names across the swarm.
2. **It leaks into adapters.** Any future adapter translating from
   Kubernetes, ECS, Prometheus, or Loki into Colony has to decide on an
   event type. Without a canonical target, each adapter invents one, and
   the event topic becomes a grab-bag of vendor-shaped names.

Colony's North Star is self-healing infrastructure across many scenarios.
For that to be a coherent runtime and not a collection of demos, the
control loop itself — not any one scenario — must own the event
vocabulary. This also aligns with DDD: the canonical events *are*
Colony's ubiquitous language, shared by role prompts, scenarios,
adapters, and operator tools.

## Decision

Colony adopts a small, fixed canonical event vocabulary that describes the
control loop in scenario-independent terms. Every scenario, adapter, and
operator tool speaks this vocabulary. Scenario-specific framing moves into
event `data` payloads and role prompts.

### Canonical events

**Episode lifecycle** — owned by the coordinator role.

| Event | Meaning |
|---|---|
| `episode.opened` | A coordination episode has started for a subject. Replaces scenario-specific "incident.opened." |
| `episode.closed` | The episode is complete (resolved, abandoned, or superseded). |

**Signals** — emitted by input adapters; the runtime's entry points.

| Event | Meaning |
|---|---|
| `change.detected` | A change has happened or is happening: deploy, config push, schema change, rollout start. `data.kind` distinguishes subtypes. |
| `health.regressed` | An SLO, alert, error rate, or latency metric has regressed. `data.kind` distinguishes subtypes. |
| `capacity.saturated` | A utilization threshold has been crossed. |
| `cost.regressed` | (Phase 5) A cost or efficiency metric has regressed. |
| `security.finding.raised` | (later) A security posture signal has been raised. |

**Context assessment** — emitted by swarm-internal cells.

| Event | Meaning |
|---|---|
| `blast_radius.requested` | Coordinator asks a scanner to evaluate a target. |
| `blast_radius.reported` | Scanner reports per-target findings. |
| `blast_radius.assessed` | Coordinator has assembled a full blast-radius picture and severity. |

**Remediation lifecycle** — the operational heart of the control loop.

| Event | Meaning |
|---|---|
| `remediation.proposed` | A specialist proposes a candidate remediation action. Multiple specialists may propose. |
| `remediation.selected` | Coordinator (or a policy) selects one proposal to execute. |
| `remediation.applied` | An action has been attempted. `data.result` carries outcome. |
| `remediation.verified` | Post-apply verification confirms (or refutes) that the action fixed the signal. |

**Governance** — first-class events, not a side channel.

| Event | Meaning |
|---|---|
| `approval.requested` | A proposed remediation requires human or policy approval. |
| `approval.granted` | Approval granted. `data.approver` records provenance. |
| `approval.denied` | Approval denied. `data.reason` required. |

**Runtime** — pre-existing; documented here for completeness.

| Event | Meaning |
|---|---|
| `runtime.gate.rejected` | An event failed envelope or policy gate. |
| `runtime.drift.detected` | Prompt drift detected for an agent cell. |

### Envelope discipline is preserved

Canonical events obey every rule in
[`swarm/constitution.md`](../../swarm/constitution.md): globally unique `id`,
dotted past-tense `type`, `source`, `subject`, stable `correlation_id`,
precise `causation_id`, partition-scheme compliance, optional `action_key`
on any event that causes a side effect. Canonical vocabulary is a naming
rule, not a new envelope.

### Scenario framing moves to `data`, with OTel semantic conventions

Scenario-specific detail that used to be encoded in the event `type` moves
into the `data` payload under a `kind` discriminator plus scenario-specific
fields. Attribute names within `data` follow OpenTelemetry semantic
conventions where a matching convention exists (`service.name`,
`k8s.deployment.name`, `k8s.namespace.name`, `deployment.environment`,
`cloud.provider`, `cloud.region`, `http.response.status_code`,
`db.system`, etc.). Scenario-specific fields that don't have a matching
OTel convention (e.g. `deployment.revision`, `burn_rate`) live alongside
OTel-conforming fields. See
[ADR-0004](0004-opentelemetry-relationship.md) for the full OTel posture.

Three worked examples follow. The canonical event `type` is always
Colony's; the inside of `data` follows OTel wherever possible.

Example 1 — a deployment-style `change.detected`:

```json
{
  "type": "change.detected",
  "subject": "checkout-svc",
  "data": {
    "kind": "deployment",
    "service.name": "checkout-svc",
    "deployment.environment": "prod",
    "k8s.namespace.name": "checkout",
    "k8s.deployment.name": "checkout-api",
    "deployment.revision": "7f3a2e1",
    "deployment.strategy": "rollingUpdate"
  }
}
```

Example 2 — a schema-drift-style `change.detected`:

```json
{
  "type": "change.detected",
  "subject": "checkout-svc",
  "data": {
    "kind": "schema_drift",
    "service.name": "checkout-svc",
    "deployment.environment": "prod",
    "producer_version": "v2.3",
    "consumer_version": "v2.2",
    "schema.field": "currency_code"
  }
}
```

Example 3 — a `health.regressed` signal from a Prometheus alert:

```json
{
  "type": "health.regressed",
  "subject": "checkout-svc",
  "data": {
    "kind": "slo_burn",
    "service.name": "checkout-svc",
    "deployment.environment": "prod",
    "alert.name": "CheckoutErrorBudgetBurnHigh",
    "alert.severity": "page",
    "burn_rate": 14.2
  }
}
```

## Migration from Phase 1 scenario events

| Current event | Canonical event | Notes |
|---|---|---|
| `deployment.completed` | `change.detected` | `data.kind = "deployment"` |
| `schema.drift.detected` | `change.detected` | `data.kind = "schema_drift"` |
| `incident.opened` | `episode.opened` | |
| `impact.scan.requested` | `blast_radius.requested` | |
| `impact.scan.reported` | `blast_radius.reported` | |
| `incident.triaged` | `blast_radius.assessed` | |
| `mitigation.proposed` | `remediation.proposed` | |
| `mitigation.selected` | `remediation.selected` | |
| `mitigation.applied` | `remediation.applied` | |
| `incident.resolved` | `remediation.verified` → `episode.closed` | Split into two events: the verification decision, and the episode close. Applier emits verification; coordinator emits close. |

Manifest `consumes` and `reasoning_triggers` lists, role prompts, and the
three shipped scenario modules (`change_failure`, `canary_regression`,
`bad_config_rollout`) all need updates. Tests track the rename; the
migration is mechanical once the mapping is accepted.

## Alternatives considered

1. **Keep scenario-flavored events; add canonical aliases later.**
   Rejected: would leave two coexistent vocabularies and force every
   adapter to pick one. The rename cost grows with every new scenario.
2. **Parallel universes: keep scenario events, add canonical events alongside,
   map in both directions.** Rejected: doubles the surface area and creates
   ambiguity about which is source-of-truth.
3. **One-to-one rename without `data.kind` discriminator.** Rejected:
   would fracture `change.detected` into `change.deployment.detected`,
   `change.schema.detected`, `change.config.detected`, etc., recreating
   the exact scenario-lock-in problem one level deeper.

## Consequences

### Positive

- The runtime has a ubiquitous language. DDD-style bounded contexts become
  possible to declare without renaming events.
- Adapters have a stable translation target. Vendor-shaped payloads stop at
  the adapter boundary.
- New scenarios are expressed as `data.kind` variants, not new event names.
- Operator tools (`mix colony.tail`, `mix colony.timeline`, etc.) become
  scenario-agnostic by default.

### Negative / accepted

- A one-time migration of manifest, role prompts, scenario modules, and
  tests. Mechanical but touches most of the repo.
- Scenario authors must be disciplined about putting framing in `data`, not
  in new event types.
- Gate/validation logic that switches on event `type` now also has to look
  at `data.kind` for signal subtyping.

### Forward-looking

- ADR-0002 relies on this vocabulary for the adapter seam.
- A future ADR will formalize bounded contexts (signal ingestion, control
  loop, action execution, governance, operator, learning); the event
  vocabulary above is already organized along those context lines.
