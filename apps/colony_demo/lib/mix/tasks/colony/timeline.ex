defmodule Mix.Tasks.Colony.Timeline do
  @shortdoc "Print causal timelines for a remediation episode from Kafka"

  @moduledoc """
  Operator view of a **remediation episode** on the agent event topic.

  Usage:

      mix colony.timeline <episode_subject>
      mix colony.timeline <episode_subject> --scenario canary_regression
      mix colony.timeline --correlation corr-incident-042

  Options:
    --scenario <name>       Scenario hint for operator output only. Current
                            Phase 1 values: `change_failure`,
                            `canary_regression`.
    --correlation <id>      Print one correlation chain directly instead of
                            discovering correlations from the episode subject.

  Fetches every message from the event topic across all partitions, decodes
  them, groups by `correlation_id`, and prints the matching timeline(s). When
  given an episode subject, the task discovers matching correlations via the
  canonical opener event (`episode.opened`) and the event subject or
  `data["episode_id"]`. Reads Kafka directly with `:brod.fetch/4` so it does
  not interfere with any running consumer groups.
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
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          scenario: :string,
          correlation: :string
        ]
      )

    if invalid != [] do
      Mix.shell().error("Unknown options: #{inspect(invalid)}")
      usage_error()
    end

    Mix.Task.run("app.start")

    brokers = Application.fetch_env!(:colony_kafka, :brokers)
    topic = Application.fetch_env!(:colony_demo, :event_topic)
    scenario = Keyword.get(opts, :scenario, "change_failure")
    episode_subject = List.first(positional)
    correlation = Keyword.get(opts, :correlation)

    events = fetch_all(brokers, topic)
    correlations = matching_correlations(events, episode_subject, correlation)

    case correlations do
      [] ->
        print_no_matches(topic, scenario, episode_subject, correlation)

      ids ->
        Enum.each(ids, fn correlation ->
          timeline =
            events
            |> Enum.filter(&(&1.correlation_id == correlation))
            |> Enum.sort_by(& &1.recorded_at, DateTime)

          print_timeline(episode_subject || "-", scenario, correlation, timeline)
        end)
    end
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

  defp matching_correlations(_events, _episode_subject, correlation)
       when is_binary(correlation) do
    [correlation]
  end

  defp matching_correlations(events, episode_subject, nil) when is_binary(episode_subject) do
    correlations_for_subject(events, episode_subject)
  end

  defp matching_correlations(_events, nil, nil) do
    usage_error()
  end

  defp correlations_for_subject(events, episode_subject) do
    events
    |> Enum.filter(fn event ->
      event.type == "episode.opened" and
        (event.subject == episode_subject or
           Map.get(event.data, "episode_id") == episode_subject)
    end)
    |> Enum.map(& &1.correlation_id)
    |> Enum.uniq()
  end

  defp print_timeline(episode_subject, scenario, correlation, events) do
    Mix.shell().info("")

    Mix.shell().info(
      "=== Timeline: #{episode_subject} " <>
        "(scenario=#{scenario}, correlation=#{correlation}, events=#{length(events)}) ==="
    )

    Enum.each(events, &print_event/1)
  end

  defp print_no_matches(topic, scenario, nil, correlation) when is_binary(correlation) do
    Mix.shell().info(
      "No events found for correlation #{correlation} in topic #{topic} (scenario=#{scenario})."
    )
  end

  defp print_no_matches(topic, scenario, episode_subject, _correlation) do
    Mix.shell().info(
      "No events found for episode #{episode_subject} in topic #{topic} (scenario=#{scenario})."
    )
  end

  defp usage_error do
    Mix.shell().error(
      "Usage: mix colony.timeline <episode_subject> [--scenario <name>] [--correlation <id>]"
    )

    exit({:shutdown, 1})
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
