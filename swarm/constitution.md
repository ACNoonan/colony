# Colony Constitution

Every cell in this swarm reads this file, then its role prompt, then begins
work. These rules are not suggestions. They are the reason replay, recovery,
and coordination work.

## Scope

The shipped role prompts today implement **README capability ladder step 1**:
change-failure response (e.g. deploy and schema regressions). The same rules
apply as the swarm widens toward assisted remediation, platform remediation,
and optimization: envelope discipline, idempotency, partitioning, causation,
and manifest truth stay fixed.

## 1. Envelope discipline

Every event emitted by a cell MUST be a valid `ColonyCore.Event`:

- `id` is globally unique for this event, not reused across retries.
- `type` is dotted, past-tense, and describes what happened (never what
  should happen next).
- `source` names the emitting cell or system.
- `subject` names the thing the event is about.
- `correlation_id` is stable across the full causal chain of work.
- `causation_id` points at the event that directly caused this one. Root
  events point at their own `correlation_id`.

## 2. Idempotency is the cell's contract

A cell MAY be restarted, replayed, or partitioned at any time. Cells MUST:

- Deduplicate by `id`. Seeing the same `id` twice is a no-op.
- When an event carries an `action_key`, treat that key as the unique
  identity of a side effect. Applying the same `action_key` more than once
  is forbidden; the cell reports `:duplicate_action` instead.

## 3. Partition discipline

The manifest declares a `partition_scheme` for every topic. Emitters MUST
set `partition_key` to match that scheme. Violating the scheme breaks cell
locality and is treated as a runtime error, not a warning.

## 4. Causation is sacred

The causal chain (`correlation_id` + `causation_id` + `sequence`) is the
only reliable narrative of what the swarm did. Cells MUST preserve it on
every emit. Breaking the chain makes replay and operator audit impossible.

## 5. Prompts are evidence

Agent cells stamp `prompt_hash` on every event they emit. A reviewer reading
the event log can reconstruct exactly which instructions were in force at
the time. Changes to this file or a role prompt change every downstream
hash — that is the point.

## 6. System cells are first-class

Not every cell runs an LLM. Dedupers, loggers, and replay controllers are
system cells declared in the manifest alongside agent cells. They obey the
same envelope discipline and the same gate.

## 7. The manifest is the truth

The live topology is whatever `swarm/manifest.exs` says it is. Ad-hoc cell
spawning outside the manifest is a bug, not a feature.
