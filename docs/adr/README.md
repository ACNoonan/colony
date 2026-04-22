# Architecture Decision Records

This directory holds the load-bearing design decisions that shape Colony's
runtime. An ADR is not a design document — it records *a decision that was
made*, the context that forced it, the alternatives considered, and the
consequences accepted.

ADRs are the canonical place to look when the question is "why is it this way
and not some other way?" If an ADR needs to change, the right move is to
supersede it with a new ADR, not to edit history.

## Conventions

- ADRs are numbered sequentially starting at `0001`.
- Filenames are `NNNN-kebab-case-title.md`.
- Each ADR carries: **Status**, **Context**, **Decision**, **Consequences**.
  Most also carry **Alternatives considered**.
- Status is one of: `Proposed`, `Accepted`, `Superseded by NNNN`, `Deprecated`.
- New ADRs land with a PR that also updates the code or roadmap to reflect
  the decision.

## Relationship to other docs

- [`README.md`](../../README.md): what Colony is and why it exists.
- [`ROADMAP.md`](../../ROADMAP.md): what Colony is eventually going to support
  and in what order.
- [`FINDINGS.md`](../../FINDINGS.md): concrete production-readiness gaps in
  what has already shipped.
- ADRs (this directory): architectural decisions that shape how any of the
  above get implemented.

## Index

- [ADR-0001: Canonical control-loop event vocabulary](0001-canonical-control-loop-events.md)
- [ADR-0002: Adapter seam for external signals and actions](0002-adapter-seam.md)
- [ADR-0003: Kubernetes and ECS as orchestrator-parity reference lanes](0003-reference-lanes.md)
- [ADR-0004: Relationship to OpenTelemetry](0004-opentelemetry-relationship.md)

## Open ADRs

Decisions the project knows it will need to make but has not yet made. An
ADR should be added when the question becomes load-bearing, not
speculatively.

- **Bounded contexts of the Colony runtime.** Once the canonical event
  vocabulary has been exercised across two or three scenarios, formalize the
  module boundaries (signal ingestion, control loop, action execution,
  governance, operator surface, learning) as DDD bounded contexts with
  explicit context maps.
- **Policy engine interface.** Internal vs OPA/Rego; where policy evaluation
  lives on the event path.
- **Approval transport.** Whether approvals are first-class canonical events
  or a separate lifecycle layered on top.
