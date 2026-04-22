# Colony

[![CI](https://github.com/ACNoonan/colony/actions/workflows/ci.yml/badge.svg)](https://github.com/ACNoonan/colony/actions/workflows/ci.yml)

`Colony` is a durable coordination runtime for self-healing infrastructure swarms.

The long-term goal is not "agents that can call tools." The goal is a runtime that can ingest operational signals, coordinate specialized workers over a durable event fabric, take bounded remediation actions, survive failure, and remain understandable to operators.

## North Star

`Colony` is aiming at a broad but coherent problem space: self-healing infrastructure.

That includes capabilities such as:

- incident response
- observability triage
- runbook automation
- Kubernetes remediation
- autoscaling and capacity interventions
- cloud cost control

Those are not separate product ideas glued together. They are different operating modes of the same control loop.

## The Core Thesis

The product thesis is that operational remediation should be built on durable coordination primitives, not ad hoc agent glue.

`Colony` should be able to:

1. ingest production signals from event-producing systems
2. partition related work into swarm cells
3. fan out to the right specialists
4. converge on a diagnosis and mitigation plan
5. apply safe, reversible, or policy-approved actions
6. survive crash and replay without duplicating side effects
7. expose enough evidence that an operator can understand what happened

If that loop works, then new domains are extensions of the same runtime rather than entirely new systems.

## Bounded Autonomy

The ambition is self-healing infrastructure, not reckless autonomy.

Early versions should bias toward:

- narrow operational scopes
- explicit policies and gates
- reversible actions
- human approval where risk is high
- replayable evidence and operator audit trails

The right progression is:

1. understand
2. recommend
3. assist
4. auto-remediate within policy

## Current Proving Ground

The first proving ground is incident coordination for change-failure response in
distributed systems.

That is the best early test because it naturally exercises:

- cross-service event fan-out and fan-in
- specialist coordination
- mitigation selection
- action idempotency
- crash recovery
- Kafka replay
- operator visibility

The shipped Phase 1 reference scenarios today are:

- a deployment/schema regression that causes downstream breakage
- a canary rollout that degrades live customer-facing behavior

Both use the same control loop: detect a risky change, open one remediation
episode, assess blast radius, compare bounded mitigations, apply one safely,
and demonstrate replay-safe recovery.

That is not the end state. It is the first hard proving ground on the way to broader self-healing infra behaviors.

## Runtime Primitives Already In Place

The repo already contains the beginnings of the runtime needed for that vision:

- event envelopes with semantic validation gates
- manifest-driven swarm topology and routing
- partition-aware execution cells
- prompt hashing and drift detection
- specialist and coordinator reasoning over Kafka events
- action-level idempotency and dedup
- crash-and-replay behavior for cells
- operator-facing tools for manifest inspection, log tailing, reasoning, and timeline reconstruction

These primitives matter more than any individual demo. They are the substrate that lets the swarm widen from incident handling into adjacent operational domains without changing the core model.

## Why Kafka Matters

Kafka is not here as infrastructure cosplay. It is part of the product argument.

Durable events make the interesting properties possible:

- explicit handoff between specialists
- partition-local coordination
- replay after process failure
- operator-visible causal chains
- auditable action history
- less hidden coupling than direct service-to-service orchestration

The flagship demo should get better as coordination scales, not worse.

## Capability Ladder

The full support surface — integration families, reference orchestrator lanes,
and phased capability growth — lives in [`ROADMAP.md`](ROADMAP.md). The
ladder below is the short form.

The roadmap should widen by reusing the same runtime semantics:

1. `change-failure response`
   Schema drift, canary regressions, bad config rollouts, downstream compatibility breaks.
2. `assisted remediation`
   Rollbacks, traffic shifts, restarts, feature-flag changes, quarantines, runbook execution.
3. `platform remediation`
   Kubernetes faults, dependency failover, saturation handling, autoscaling interventions.
4. `optimization loops`
   Cost control, efficiency tuning, capacity shaping, policy-driven optimization.

Each step should feel like the same system getting wider, not like a new demo stitched onto the repo.

## Repo Shape

This repo is intentionally organized around the runtime boundary:

- `apps/colony_core`: event envelopes, manifests, tools, and shared runtime primitives
- `apps/colony_cell`: supervised execution cells, local state, replay, and reasoning hooks
- `apps/colony_kafka`: Kafka boundary and adapter seam
- `apps/colony_demo`: reference narratives, fixtures, and operator tasks
- `docker-compose.yml`: local Redpanda + Console stack
- `Makefile`: smallest useful local operator workflow

The implementation stays dependency-light on purpose. The goal is to preserve the architecture and semantics before locking in deeper framework choices.

## Great Devex

A strong devex for this project should feel like platform engineering, not framework archaeology.

- One command starts the local event fabric.
- One command runs a meaningful swarm scenario.
- The first scenario shows coordination, failure, replay, and safe action semantics.
- Topic names, event envelopes, and cell boundaries are explicit.
- Operators can inspect partitions, offsets, replay status, cell state, and causal timelines early.
- New domains can be added by composing the same primitives, not by rewriting the runtime.

The litmus test is simple: a new developer should understand why the durable event fabric matters within 15 minutes.

## Local Stack

This repo currently uses Redpanda as the first Kafka-compatible backend because it keeps the local story simple while preserving the production shape.

Start the stack:

```bash
make up
```

Inspect brokers and topics:

```bash
make ps
make kafka-topics
```

Open the Kafka console at [http://localhost:8080](http://localhost:8080).

## Development

Run the core local checks:

```bash
mix deps.get
mix format --check-formatted
mix test
```

## Contributor Workflow

1. Fork and create a branch for your change.
2. Add or update tests when behavior changes.
3. Run `mix deps.get`, `mix format --check-formatted`, and `mix test`.
4. Open a PR with a short summary and test plan.

## Current Constraint

The runtime primitives compile locally, but the project is still in a
hardening phase rather than a production-ready one. The main constraints are
runtime safety and operator trust: gate policy is still conservative by
default, some replay and async publish edges are explicitly tracked in
`FINDINGS.md`, and the proving ground is still narrow compared to the full
self-healing infrastructure vision.

## Near-Term Priorities

These are the right next implementation steps:

1. Keep hardening the runtime primitives already in place: gates, replay, dedup, prompt drift detection, and operator visibility. Concrete gaps and how to test them live in [`FINDINGS.md`](FINDINGS.md).
2. Expand the proving ground from one incident path into a small family of operational failure scenarios that all exercise the same coordination loop.
3. Add safer action boundaries: policy checks, approvals, and clearer remediation classes.
4. Build out operator-facing evidence: snapshots, timelines, gate views, and clearer replay status.
5. Grow from incident coordination into adjacent self-healing infrastructure capabilities without diluting the core runtime model.
