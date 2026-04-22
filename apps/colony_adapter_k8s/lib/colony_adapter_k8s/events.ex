defmodule ColonyAdapterK8s.Events do
  @moduledoc """
  Translates real Kubernetes `Event` objects into canonical Colony events.

  Recognized shapes (per
  [ADR-0001](../../../../docs/adr/0001-canonical-control-loop-events.md)
  and
  [ADR-0004](../../../../docs/adr/0004-opentelemetry-relationship.md)):

    * Deployment rollout (`involvedObject.kind = "Deployment"`,
      `reason = "ScalingReplicaSet"`) → `change.detected`,
      `data.kind = "deployment"`.
    * Pod crashloop (`involvedObject.kind = "Pod"`, `reason = "BackOff"`,
      `type = "Warning"`) → `health.regressed`, `data.kind = "crashloop"`.
    * Pod scheduling failure (`reason = "FailedScheduling"`) →
      `capacity.saturated`, `data.kind = "scheduling_failure"`.
    * Pod eviction (`reason = "Evicted"`) → `capacity.saturated`,
      `data.kind = "eviction"`.

  Payloads the adapter does not recognize return `[]`.

  ## Identity and correlation

  Event ids and correlation ids are deterministic in the vendor payload's
  `metadata.uid`. Replaying the same fixture twice yields events with
  identical `id`s so downstream cells dedupe by `id`.
  """

  @behaviour ColonyAdapterK8s.InputAdapter

  alias ColonyCore.Event

  @source "adapter.k8s.events"

  @impl true
  def translate(payload) when is_map(payload) do
    case classify(payload) do
      {:ok, canonical_type, kind, extra_data} ->
        [build_event(payload, canonical_type, kind, extra_data)]

      :skip ->
        []
    end
  end

  def translate(_), do: []

  # Classification
  # --------------

  defp classify(%{
         "reason" => "ScalingReplicaSet",
         "involvedObject" => %{"kind" => "Deployment"} = obj,
         "message" => message
       }) do
    namespace = Map.get(obj, "namespace")

    data = %{
      "k8s.deployment.name" => Map.get(obj, "name"),
      "k8s.namespace.name" => namespace,
      "deployment.environment" => namespace,
      "deployment.revision" => extract_revision(message)
    }

    {:ok, "change.detected", "deployment", drop_nils(data)}
  end

  defp classify(
         %{
           "reason" => "BackOff",
           "type" => "Warning",
           "involvedObject" => %{"kind" => "Pod"} = obj
         } = event
       ) do
    namespace = Map.get(obj, "namespace")
    pod_name = Map.get(obj, "name")

    data = %{
      "k8s.pod.name" => pod_name,
      "k8s.namespace.name" => namespace,
      "k8s.container.name" => extract_container_name(obj),
      "deployment.environment" => namespace,
      "restart_count" => Map.get(event, "count")
    }

    {:ok, "health.regressed", "crashloop", drop_nils(data)}
  end

  defp classify(%{
         "reason" => "FailedScheduling",
         "involvedObject" => %{"kind" => "Pod"} = obj,
         "message" => message
       }) do
    namespace = Map.get(obj, "namespace")

    data = %{
      "k8s.pod.name" => Map.get(obj, "name"),
      "k8s.namespace.name" => namespace,
      "deployment.environment" => namespace,
      "k8s.event.reason" => "FailedScheduling",
      "scheduling.unavailable_nodes" => extract_unavailable_nodes(message),
      "scheduling.reason_hint" => extract_scheduling_hint(message)
    }

    {:ok, "capacity.saturated", "scheduling_failure", drop_nils(data)}
  end

  defp classify(%{
         "reason" => "Evicted",
         "involvedObject" => %{"kind" => "Pod"} = obj,
         "message" => message
       }) do
    namespace = Map.get(obj, "namespace")

    data = %{
      "k8s.pod.name" => Map.get(obj, "name"),
      "k8s.namespace.name" => namespace,
      "deployment.environment" => namespace,
      "k8s.event.reason" => "Evicted",
      "eviction.node_condition" => extract_node_condition(message)
    }

    {:ok, "capacity.saturated", "eviction", drop_nils(data)}
  end

  defp classify(_), do: :skip

  # Envelope construction
  # ---------------------

  defp build_event(payload, canonical_type, kind, extra_data) do
    uid = fetch_uid!(payload)
    service = service_name(payload)
    correlation_id = "corr-k8s-#{uid}"

    data =
      extra_data
      |> Map.put("kind", kind)
      |> Map.put("service.name", service)

    Event.new(%{
      id: "evt-k8s-#{uid}",
      type: canonical_type,
      source: @source,
      subject: service,
      partition_key: service,
      correlation_id: correlation_id,
      causation_id: correlation_id,
      sequence: 1,
      data: data
    })
  end

  defp fetch_uid!(payload) do
    case get_in(payload, ["metadata", "uid"]) do
      uid when is_binary(uid) and byte_size(uid) > 0 ->
        uid

      other ->
        raise ArgumentError,
              "k8s Event payload missing metadata.uid (got #{inspect(other)}); " <>
                "required for deterministic Colony event id"
    end
  end

  # service.name derivation
  # -----------------------
  #
  # Real k8s Event objects don't carry the involved object's labels.
  # Derive service.name from the workload name using common k8s naming
  # conventions (Deployment → ReplicaSet hash → Pod hash).

  defp service_name(%{"involvedObject" => %{"kind" => "Deployment", "name" => name}}),
    do: name

  defp service_name(%{"involvedObject" => %{"kind" => "ReplicaSet", "name" => name}}),
    do: strip_trailing_segments(name, 1)

  defp service_name(%{"involvedObject" => %{"kind" => "Pod", "name" => name}}),
    do: strip_trailing_segments(name, 2)

  defp service_name(%{"involvedObject" => %{"name" => name}}), do: name

  defp strip_trailing_segments(name, n) when is_binary(name) and is_integer(n) do
    parts = String.split(name, "-")

    if length(parts) > n do
      parts |> Enum.take(length(parts) - n) |> Enum.join("-")
    else
      name
    end
  end

  # Message parsers
  # ---------------

  # Matches "Scaled up replica set checkout-api-7f3a2e1 to 3" and pulls the
  # trailing hash segment of the replica set name as the revision hint.
  defp extract_revision(message) when is_binary(message) do
    case Regex.run(~r/replica set ([^\s]+)/, message) do
      [_, rs_name] ->
        case String.split(rs_name, "-") do
          parts when length(parts) >= 2 -> List.last(parts)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp extract_revision(_), do: nil

  # "spec.containers{api}" → "api"
  defp extract_container_name(%{"fieldPath" => field_path}) when is_binary(field_path) do
    case Regex.run(~r/containers\{([^}]+)\}/, field_path) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp extract_container_name(_), do: nil

  # "0/3 nodes are available: 3 Insufficient memory." → 3
  defp extract_unavailable_nodes(message) when is_binary(message) do
    case Regex.run(~r/^(\d+)\/(\d+) nodes are available/, message) do
      [_, unavailable, _total] -> String.to_integer(unavailable)
      _ -> nil
    end
  end

  defp extract_unavailable_nodes(_), do: nil

  # "0/3 nodes are available: 3 Insufficient memory." → "Insufficient memory"
  defp extract_scheduling_hint(message) when is_binary(message) do
    case Regex.run(~r/:\s*\d+\s+(.+?)\.?$/, message) do
      [_, hint] -> String.trim(hint)
      _ -> nil
    end
  end

  defp extract_scheduling_hint(_), do: nil

  # "The node had condition: [DiskPressure]." → "DiskPressure"
  defp extract_node_condition(message) when is_binary(message) do
    case Regex.run(~r/\[([^\]]+)\]/, message) do
      [_, condition] -> condition
      _ -> nil
    end
  end

  defp extract_node_condition(_), do: nil

  defp drop_nils(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
