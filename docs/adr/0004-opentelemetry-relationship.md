# ADR-0004: Relationship to OpenTelemetry

- **Status:** Accepted — 2026-04-22
- **Depends on:** [ADR-0001](0001-canonical-control-loop-events.md),
  [ADR-0002](0002-adapter-seam.md)

## Context

OpenTelemetry (OTel) is the industry standard for vendor-neutral
observability data: traces, metrics, logs, and — increasingly — events.
It ships with three assets that are directly relevant to Colony:

1. **Semantic Conventions** — a large, governed registry of standardized
   attribute names for resources, services, Kubernetes, cloud providers,
   HTTP, databases, messaging, RPC, etc. (`service.name`,
   `k8s.deployment.name`, `k8s.namespace.name`, `deployment.environment`,
   `cloud.provider`, `cloud.region`, `http.response.status_code`,
   `db.system`, and hundreds more).
2. **OTLP** — a well-defined wire protocol for shipping
   traces/metrics/logs/events between systems.
3. **Resource model** — every OTel signal carries a `Resource`
   description of what emitted it.

OTel does *not* define:

- A control-plane vocabulary for operational events (deployments,
  alerts, rollbacks, approvals, remediations).
- Durable causal-chain semantics across long-running operational
  episodes. Trace and span IDs describe a distributed request, not a
  remediation that may span hours or days.
- Alert / rollback / approval schemas that Colony could adopt wholesale.

Colony needs a clear, published stance on where OTel ends and Colony's
own runtime vocabulary begins — otherwise adapters will make ad-hoc
decisions, attribute names will drift across lanes, and the runtime
will accidentally reinvent names OTel already governs.

## Decision

Colony adopts OpenTelemetry for observability-layer concerns, while
keeping control-loop semantics entirely under
[ADR-0001](0001-canonical-control-loop-events.md). Four specific
commitments follow.

### 1. OTel semantic conventions govern attribute names in `data`

Within a canonical event's `data` payload, attribute names follow
OpenTelemetry semantic conventions *where a matching convention
exists*. Scenario authors and adapter authors do not invent new names
for concepts OTel has already standardized.

Worked examples of canonical events with OTel-conforming `data`
attributes live in
[ADR-0001](0001-canonical-control-loop-events.md#scenario-framing-moves-to-data-with-otel-semantic-conventions).

Policy for fields without an OTel convention: scenario-specific fields
that don't have an OTel semantic convention (e.g. `deployment.revision`,
`burn_rate`) live alongside OTel-conforming fields in the same `data`
payload. When OTel later adds a convention for a concept Colony has
already named, Colony aligns on the next breaking opportunity rather
than carrying two names in parallel.

The canonical event type (`change.detected`, `remediation.proposed`,
etc.) is always Colony's. OTel governs the *inside* of `data`; ADR-0001
governs the *outside*.

### 2. Input adapters accept OTLP where the source speaks it

Any signal source that produces OTLP (many observability vendors,
Prometheus with the OTel receiver, Loki with the OTel receiver, the OTel
Collector itself as a forwarder, OTel-instrumented applications) is
consumed via OTLP at Colony's input adapters. The adapter translates the
OTLP signal into a canonical event using the `Resource` + attributes
already present.

Non-OTLP sources (e.g. Alertmanager webhooks, GitHub Actions webhooks,
Kubernetes API event streams) remain supported. OTLP is the *preferred*
ingestion path, not the only one.

### 3. Colony's own activity may be emitted as OTel signals

Output adapters and internal runtime components MAY emit OTel spans,
events, or logs describing Colony's own work — e.g. a remediation
execution emitted as a span, an episode emitted as a sequence of OTel
events. This makes Colony self-observable using the same tooling its
users already have deployed.

Self-observability is optional, not load-bearing. The Kafka event log
remains the authoritative record of what the runtime did; OTel emission
is a convenience for operators whose dashboards already live in
Grafana/Tempo.

### 4. Trace context coexists with causation context; it does not replace it

When an input signal arrives with OTel trace context (a `trace_id` /
`span_id` from an OTLP payload), the input adapter SHOULD preserve them
as attributes within `data` (e.g. `trace.id`, `span.id`). Those values
are evidence — they let an operator jump from an incident timeline to
a distributed trace that produced a signal.

They are not Colony's causation chain. Colony's `correlation_id` and
`causation_id` remain the authoritative links across the runtime's
events. A remediation episode may outlive any trace, may span many
traces, and may have no originating trace at all. The constitution's
causation discipline (§4) is unchanged.

## Alternatives considered

1. **Adopt OTel events as the canonical control-loop vocabulary.**
   Rejected: OTel does not define the events Colony needs
   (`remediation.proposed`, `episode.opened`, `approval.requested`,
   etc.), and the OTel event schema is still evolving. Anchoring the
   runtime's vocabulary to a moving target would fracture ADR-0001.
2. **Ignore OTel; define Colony's own attribute names.** Rejected:
   would reinvent the entire resource and service attribute registry
   for no benefit, create naming drift across adapters, and produce
   `data` payloads incompatible with existing dashboards and tooling.
3. **Use OTel trace IDs as Colony's causation chain.** Rejected: trace
   context is per-request, Colony's causation is per-episode. Collapsing
   them would either force every episode to fit inside one trace (too
   restrictive) or overload trace semantics (confusing for anyone
   reading traces in their normal tooling).

## Consequences

### Positive

- One less thing for each scenario and adapter author to design.
- Colony event `data` payloads are immediately readable to anyone
  familiar with OTel, which is an increasing share of operators.
- A single OTLP input adapter covers a broad set of upstream sources —
  Prometheus (via OTel receiver), Loki (via OTel receiver), any
  OTel-instrumented application, any vendor that exports OTLP.
- Colony remediations can show up as spans in existing Grafana/Tempo
  setups without a bespoke integration story.
- Two-lane parity (ADR-0003) becomes easier: k8s and ECS adapters use
  the same attribute vocabulary because OTel already standardizes
  `k8s.*` and `cloud.*`.

### Negative / accepted

- `data` payloads are slightly more verbose (`k8s.deployment.name`
  rather than `deployment`). Acceptable — the names are already sunk
  cost for anyone who has touched OTel, and verbosity prevents
  ambiguity.
- OTel semantic conventions are a moving target. Some names stabilize,
  others change before GA. Policy: track OTel stable conventions
  strictly; treat experimental conventions as opt-in until stable.
- Occasional mismatch between an OTel convention and what a scenario
  naturally wants to call a thing. Default: use the OTel name. Deviate
  only with a documented reason in the scenario module.

### Forward-looking

- When OTel's emerging event conventions (deployment events,
  Kubernetes events as OTel events) stabilize, Colony input adapters
  should consume those directly rather than re-translating from
  vendor-native shapes. Track the OTel events SIG work; revisit this
  ADR when a relevant convention goes stable.
- A future ADR will cover self-observability details (which Colony
  internals emit which OTel signals, exporter configuration, sampling
  strategy) once Colony is being operated against real dashboards and
  the question becomes load-bearing.
