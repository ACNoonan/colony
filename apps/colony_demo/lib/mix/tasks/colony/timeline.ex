defmodule Mix.Tasks.Colony.Timeline do
  @shortdoc "Print the replayed causal timeline for an incident from Kafka"

  @moduledoc """
  Usage: mix colony.timeline <incident_id>

  Fetches every message from the event topic across all partitions,
  decodes them, groups by correlation_id, and prints the timeline for
  each correlation that references the given incident_id. This reads
  Kafka directly with `:brod.fetch/4` so it does not interfere with any
  running consumer groups.
  """

  use Mix.Task

  require Record

  alias ColonyCore.Event

  Record.defrecord(
    :kafka_message,
    Record.extract(:kafka_message, from_lib: "kafka_protocol/include/kpro_public.hrl")
  )

  @partitions 0..2

  @impl Mix.Task
  def run([incident_id]) do
    Mix.Task.run("app.start")

    brokers = Application.fetch_env!(:colony_kafka, :brokers)
    topic = Application.fetch_env!(:colony_demo, :event_topic)

    events = fetch_all(brokers, topic)
    correlations = correlations_for(events, incident_id)

    case correlations do
      [] ->
        Mix.shell().info("No events found for incident #{incident_id} in topic #{topic}.")

      ids ->
        Enum.each(ids, fn correlation ->
          timeline =
            events
            |> Enum.filter(&(&1.correlation_id == correlation))
            |> Enum.sort_by(& &1.recorded_at, DateTime)

          print_timeline(incident_id, correlation, timeline)
        end)
    end
  end

  def run(_) do
    Mix.shell().error("Usage: mix colony.timeline <incident_id>")
    exit({:shutdown, 1})
  end

  defp fetch_all(brokers, topic) do
    for partition <- @partitions,
        message <- fetch_partition(brokers, topic, partition) do
      value = kafka_message(message, :value)

      case Event.decode(value) do
        {:ok, event} -> event
        {:error, _} -> nil
      end
    end
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_partition(brokers, topic, partition) do
    case :brod.fetch(brokers, topic, partition, 0) do
      {:ok, {_hw, messages}} -> messages
      {:ok, messages} when is_list(messages) -> messages
      {:error, _} -> []
    end
  end

  defp correlations_for(events, incident_id) do
    events
    |> Enum.filter(fn event ->
      event.type == "incident.opened" and
        (event.subject == incident_id or
           Map.get(event.data, "incident_id") == incident_id)
    end)
    |> Enum.map(& &1.correlation_id)
    |> Enum.uniq()
  end

  defp print_timeline(incident_id, correlation, events) do
    Mix.shell().info("")

    Mix.shell().info(
      "=== Timeline: #{incident_id} " <>
        "(correlation=#{correlation}, events=#{length(events)}) ==="
    )

    Enum.each(events, &print_event/1)
  end

  defp print_event(event) do
    ts = event.recorded_at && DateTime.to_iso8601(event.recorded_at)

    Mix.shell().info(
      "#{ts}  seq=#{event.sequence}  #{event.type}  " <>
        "subject=#{event.subject}  source=#{event.source}"
    )

    Mix.shell().info("    id=#{event.id}  causation=#{event.causation_id}")

    if event.action_key, do: Mix.shell().info("    action_key=#{event.action_key}")

    Mix.shell().info("    data=#{inspect(event.data)}")
  end
end
