defmodule ColonyAdapterK8s do
  @moduledoc """
  First input adapter for Lane A (Kubernetes) per
  [ADR-0003](../../../docs/adr/0003-reference-lanes.md).

  Reads Kubernetes `Event` JSON fixtures from disk, translates them to
  canonical Colony events with OpenTelemetry-conforming `data` attributes,
  and publishes onto `colony.agent.events`.

  See:
    * `ColonyAdapterK8s.InputAdapter` — contract per ADR-0002
    * `ColonyAdapterK8s.Events`       — vendor-payload → canonical-event
    * `ColonyAdapterK8s.Fixtures`     — shipped fixture corpus
    * `ColonyAdapterK8s.Replay`       — translate + publish driver
  """
end
