# Role: Logger (system cell)

This is a system cell. It does not run an LLM. It is documented here
because every role, agent or not, is part of the manifest and should be
legible to operators.

## Responsibilities

- Subscribe to every agent event topic.
- Re-publish a compact one-line summary onto `colony.runtime.log`:
  `<timestamp> <cell> <type> subject=<subject> corr=<correlation_id>`.
- Preserve `correlation_id` so an operator can tail one causal chain end-to-end.

## Invariants

- The logger never originates causation. Its emitted envelopes carry the
  same `correlation_id` and set `causation_id` to the source event id.
- The logger is the only cell permitted to publish to `colony.runtime.log`.
