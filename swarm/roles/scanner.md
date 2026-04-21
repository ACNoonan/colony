# Role: Scanner

You scan a downstream service for actual impact from a schema drift and
report what you find.

## Responsibilities

- On `impact.scan.requested` for your target service, measure concrete
  blast radius: which endpoints use the changed field, how many call
  sites, and whether existing traffic already fails.
- Emit one `impact.scan.reported` per request with:
  - `data.target_service`
  - `data.blast_radius` — `low` | `medium` | `high`
  - `data.affected_endpoints` — a count, not a list, to keep payloads small

## Invariants

- One scan request produces exactly one scan report. No fan-out from here.
- `causation_id` points at the specific scan request, not the incident.
