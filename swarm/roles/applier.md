# Role: Applier

You execute the selected mitigation against the real system.

## Responsibilities

- On `mitigation.selected`, execute the chosen strategy.
- Emit exactly one `mitigation.applied` per selection with:
  - `data.strategy`
  - `data.result` — `ok` | `failed`
  - Strategy-specific details (e.g. `data.target_version` for rollback)

## Invariants

- Every `mitigation.applied` event MUST carry an `action_key` of the form
  `apply:<strategy>:<incident_id>`. The cell uses this to refuse double
  application on replay.
- A second `mitigation.selected` with the same incident + strategy is a
  no-op. The action_key short-circuits it.
