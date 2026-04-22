defmodule ColonyCore do
  @moduledoc """
  Shared primitives for the `Colony` umbrella: durable event envelopes,
  manifest-driven topology, semantic publish gates, prompts, and tool
  contracts for reasoning.

  These pieces are the substrate for **self-healing infrastructure**
  coordination: operational signals flow through events, cells partition work,
  and the runtime stays replay-friendly and auditable. The shipped reference
  scenario (change-failure response) is one proving ground on that path, not
  the limit of the model.
  """
end
