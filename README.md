# Colony

[![CI](https://github.com/ACNoonan/colony/actions/workflows/ci.yml/badge.svg)](https://github.com/ACNoonan/colony/actions/workflows/ci.yml)

`Colony` is an early-stage Jido + Kafka runtime project for coordination-heavy agent systems.

The point of this repo is not to prove that "agents can call tools." The point is to prove that a distributed runtime can coordinate lots of specialized workers over a durable event fabric, survive failure, and stay understandable to operators.

## Demo Narrative

The flagship demo should tell a story that only gets better as coordination scales:

1. Many enterprise systems publish events into Kafka.
2. Related work is partitioned into swarm cells.
3. Cells coordinate through durable events instead of direct service-to-service coupling.
4. A cell crashes mid-flight.
5. Supervision restarts it, Kafka replay restores state, and duplicate side effects are avoided.

That is a better proof than "auto incident triage" because it showcases communication, partitioning, fan-in/fan-out, replay, and runtime semantics.

## Repo Shape

This repo is intentionally organized around the runtime boundary:

- `apps/colony_core`: event envelopes and shared runtime primitives
- `apps/colony_cell`: local supervised execution cell
- `apps/colony_kafka`: Kafka boundary and adapter seam
- `apps/colony_demo`: reference narrative and demo fixtures
- `docker-compose.yml`: local Redpanda + Console stack
- `Makefile`: smallest useful local operator workflow

The first implementation is dependency-light on purpose. It preserves the architecture and demo story before we lock in exact Jido and Kafka client integrations.

## Great Devex

A strong devex for this project should feel like platform engineering, not framework archaeology.

- One command starts the local event fabric.
- One command runs the demo.
- The first demo shows failure, replay, and coordination.
- Topic names, event envelopes, and cell boundaries are explicit.
- Operators can see partitions, offsets, replay status, and cell snapshots early.
- Python and JavaScript clients come after the runtime semantics are clear.

The litmus test is simple: a new developer should understand why Kafka matters within 15 minutes.

## Local Stack

This repo is currently set up to use Redpanda as the first Kafka-compatible backend because it keeps the local story simple while preserving the production shape.

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

This machine currently does not have `elixir` or `mix` installed, and Docker is installed but the daemon was not running while this repo was scaffolded. That means the project structure is in place, but the Elixir code has not yet been compiled or generated from Mix tooling on this machine.

## Amazing First Steps

These are the right first implementation steps for the next pass:

1. Install or containerize the Elixir toolchain so `mix test` and `mix format` work locally.
2. Add Jido as the execution kernel inside `colony_cell`.
3. Add a real Kafka client adapter in `colony_kafka`.
4. Build the first demo around a coordination-heavy enterprise flow rather than a chatbot.
5. Add a tiny operator surface that exposes cell state, processed event IDs, and replay progress.

## Best Demo Candidate

A deployment in service A triggers schema drift and downstream behavioral regressions across 12 services. The swarm detects impacted consumers, spins up specialist agents by domain, proposes mitigation, applies safe compensations, coordinates rollback/canary decisions, and replays the entire causal chain afterward.

All of those make Kafka feel native instead of bolted on.

## Opinionated Next Demo

If I had to pick one, I would start with `quote-to-fulfillment`.

Why:

- It naturally has many producers.
- It benefits from partitioned coordination by account, region, or order.
- It demonstrates fan-out and fan-in clearly.
- Replay and idempotency matter in a way everybody understands.
- It feels like infrastructure, not just AI theater.
