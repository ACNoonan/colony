# ADR-0002: Adapter seam for external signals and actions

- **Status:** Accepted — 2026-04-22
- **Depends on:** [ADR-0001](0001-canonical-control-loop-events.md)

## Context

[ADR-0001](0001-canonical-control-loop-events.md) commits Colony to a
canonical control-loop event vocabulary. For that commitment to hold,
vendor-specific code must have a structural home that keeps it out of the
runtime core. Otherwise two things happen over time: vendor schemas leak
into role prompts and coordinator logic; and the canonical vocabulary
drifts scenario-by-scenario because no component is actually responsible
for enforcing the translation.

The runtime already has a natural boundary — the Kafka event fabric. What
it lacks is an explicit convention that says: "everything outside this
boundary speaks vendor; everything inside speaks canonical."

## Decision

Colony has two kinds of adapters, both anchored at the Kafka boundary.

### Input adapters

An input adapter consumes vendor-specific signal data (a Kubernetes event
stream, an Alertmanager webhook, an ECS EventBridge message, a Loki query
result, a GitHub Actions webhook) and emits canonical signal events into
Kafka. Its only public output is canonical events with well-formed
envelopes.

Input adapters are responsible for:

- authenticating and connecting to the source system
- normalizing payload shape into the canonical `data.kind` + scenario
  fields convention
- setting `source`, `subject`, `correlation_id`, and `causation_id`
  correctly (root events point their `causation_id` at their own
  `correlation_id`)
- preserving enough vendor detail in `data` to support audit and replay
- producing idempotent emits — seeing the same upstream signal twice must
  not produce two canonical events

Input adapters do not participate in reasoning, do not call other cells,
and do not maintain scenario state. They are stateless translators.

### Output adapters

An output adapter consumes canonical `remediation.selected` (and later,
`approval.granted` plus other action-triggering events) and produces a
vendor-specific side effect: a `kubectl` call, an ECS service update, a
Discord message, a Linear issue creation, a feature-flag toggle.

Output adapters are responsible for:

- honoring `action_key` for at-most-once side-effect semantics (see
  [constitution §2](../../swarm/constitution.md))
- translating canonical action intent (e.g. `remediation.selected` with
  `data.kind = "rollback"` and `data.target`) into the right vendor API
  call
- emitting `remediation.applied` with a truthful `data.result`
- surfacing vendor-specific failure modes in canonical `data.error`
  structure

Output adapters do not decide *which* action to take — that is the
coordinator's job. They execute a specific canonical action.

### Seam placement

The Kafka topic boundary is the seam. A topic is either:

- **external-facing** — an input adapter produces canonical events onto it
  from a vendor source, or an output adapter consumes canonical events
  from it and produces vendor side effects;
- **internal** — swarm cells coordinate among themselves entirely in
  canonical vocabulary.

No runtime cell (coordinator, specialist, detector, scanner, applier,
logger, gate auditor) speaks vendor schema. If a cell appears to need
vendor-specific knowledge, the correct fix is to push that knowledge into
an adapter.

## Alternatives considered

1. **In-process translation inside each cell.** Rejected: spreads vendor
   schema across the runtime and defeats the canonical vocabulary.
2. **A single monolithic translator service.** Rejected: makes adapter
   isolation, per-vendor rate limiting, and per-vendor credential scoping
   much harder. A per-vendor adapter process is cheap and well-aligned
   with Kafka consumer group boundaries.
3. **No explicit seam — let scenarios decide where vendor code lives.**
   Rejected: this is the status quo and is exactly what ADR-0001 is
   walking away from.

## Consequences

### Positive

- A new orchestrator, observability backend, or notification target is
  added by writing one input adapter and/or one output adapter, with zero
  changes to the runtime.
- Adapters are independently testable: feed recorded vendor payloads in,
  assert canonical events come out.
- Per-vendor concerns (rate limits, retries, auth, API version drift) stay
  contained.
- Phase 1's "simulated real signal" strategy fits naturally: a fixture
  replayer is just an input adapter reading from disk instead of a live
  vendor API.

### Negative / accepted

- Two translation hops (vendor → canonical → vendor) for end-to-end flows.
  Acceptable in exchange for the structural isolation; latency is not
  the optimization target at Colony's scale.
- A small amount of duplicated translation logic when the same vendor acts
  as both a signal source and an action target (e.g. Kubernetes). Keep
  the shared helpers in a per-vendor library, not in the runtime core.

### Forward-looking

- [ADR-0003](0003-reference-lanes.md) specifies which vendor adapters are
  first-class under the two reference lanes.
- A future ADR will formalize the adapter package layout (Elixir
  application boundaries, config surface, credential handling) once the
  first real adapter lands.
