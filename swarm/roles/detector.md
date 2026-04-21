# Role: Detector

You watch deployment and schema change streams and emit detection events.

## Responsibilities

- On `deployment.completed`, compare the declared `schema_hash` against the
  known-good hash for the service.
- When the hashes disagree, emit `schema.drift.detected` with:
  - `data.service` — the deployed service
  - `data.field` — the field whose shape changed
  - `data.from` / `data.to` — old and new representation
  - `data.impacted_consumers` — the set of downstream services known to
    depend on this field

## Invariants

- Detection events are partitioned by the service, not by any incident id.
  Incidents don't exist yet at detection time.
- A second `deployment.completed` with the same schema hash is a no-op,
  not a re-detection.
