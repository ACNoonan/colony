defmodule ColonyKafka do
  @moduledoc """
  Kafka boundary for the swarm runtime.

  The runtime value proposition depends on Kafka being a first-class event log,
  not just a transport adapter hidden under higher-level abstractions.

  Every `publish/2` runs the envelope gate before hitting the adapter.
  Gate mode (`:warn` | `:enforce` | `:disabled`) is read from
  `config :colony_core, :gate_mode`. Default is `:warn` so a new rule
  surfaces in the log + `colony.runtime.gate.rejected` topic before it
  starts blocking traffic.
  """

  require Logger

  alias ColonyCore.Event
  alias ColonyCore.Envelope.Gate

  @rejection_topic "colony.runtime.gate.rejected"

  @callback publish(topic :: binary(), event :: Event.t()) :: :ok | {:error, term()}
  @callback subscribe(topic :: binary(), opts :: keyword()) :: :ok | {:error, term()}

  def publish(topic, %Event{} = event, opts \\ []) when is_binary(topic) do
    if Keyword.get(opts, :bypass_gate, false) do
      adapter().publish(topic, event)
    else
      case Gate.check(event, topic) do
        :ok ->
          adapter().publish(topic, event)

        {:error, violation} ->
          handle_violation(topic, event, violation)
      end
    end
  end

  def subscribe(topic, opts \\ []) when is_binary(topic) do
    adapter().subscribe(topic, opts)
  end

  def adapter do
    Application.fetch_env!(:colony_kafka, :adapter)
  end

  def gate_mode do
    Application.get_env(:colony_core, :gate_mode, :warn)
  end

  defp handle_violation(topic, event, violation) do
    emit_rejection(topic, event, violation)

    case gate_mode() do
      :enforce ->
        {:error, {:gate, violation}}

      _warn_or_disabled ->
        adapter().publish(topic, event)
    end
  end

  defp emit_rejection(topic, %Event{} = event, {rule, details}) do
    rejection =
      Event.new(%{
        id: "evt-gate-#{System.unique_integer([:positive])}",
        type: "runtime.gate.rejected",
        source: "runtime.gate",
        subject: event.id,
        partition_key: "gate",
        correlation_id: event.correlation_id,
        causation_id: event.id,
        tenant_id: event.tenant_id,
        swarm_id: event.swarm_id,
        data: %{
          "rule" => Atom.to_string(rule),
          "details" => stringify(details),
          "origin_topic" => topic,
          "origin_type" => event.type,
          "origin_source" => event.source,
          "gate_mode" => Atom.to_string(gate_mode())
        }
      })

    Logger.warning(
      "gate #{gate_mode()} #{rule}: #{inspect(details)} " <>
        "(event #{event.id} on #{topic})"
    )

    case adapter().publish(@rejection_topic, rejection) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("gate rejection publish failed: #{inspect(reason)}")
        :ok
    end
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp stringify_value(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)
  defp stringify_value(v) when is_map(v), do: stringify(v)
  defp stringify_value(v), do: inspect(v)
end
