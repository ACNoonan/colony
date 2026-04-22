defmodule ColonyAdapterK8s.InputAdapter do
  @moduledoc """
  Contract for input adapters per
  [ADR-0002](../../../../docs/adr/0002-adapter-seam.md).

  An input adapter consumes vendor-specific signal data and emits canonical
  Colony events. It is a stateless translator: no reasoning, no cross-cell
  calls, no persistence between runs (ADR-0002).

  ## Envelope responsibilities

  An adapter MUST set, on every emitted event:

    * `source` — a string naming the adapter itself (e.g.
      `"adapter.k8s.events"`), not the upstream vendor component.
    * `subject` — the thing the signal is about, chosen from the canonical
      vocabulary (typically a `service.name` or workload id). See
      [ADR-0001](../../../../docs/adr/0001-canonical-control-loop-events.md).
    * `correlation_id` — stable for the full causal chain this signal
      initiates. A root adapter emit (no prior Colony event) sets
      `causation_id` to its own `correlation_id` per ADR-0002.
    * `partition_key` — matches the destination topic's partition scheme.

  ## Idempotency

  Event ids MUST be deterministic in the vendor payload. Replaying the same
  upstream signal MUST yield an event with the identical `id` so downstream
  cells dedupe by `id` (`swarm/constitution.md` §2).

  Signals are not side effects, so `action_key` is not set on input-adapter
  emits.

  ## Conservative classification

  A payload that the adapter does not recognize returns `[]`. Input
  adapters are never allowed to invent canonical event types for unfamiliar
  vendor shapes — that would defeat ADR-0001.
  """

  alias ColonyCore.Event

  @callback translate(vendor_payload :: map()) :: [Event.t()]
end
