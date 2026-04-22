defmodule Mix.Tasks.Colony.Adapter.K8s.Replay do
  @shortdoc "Replay Kubernetes Event fixtures through the Lane A input adapter"

  @moduledoc """
  Operator entry point for the Lane A Kubernetes input adapter.

  Loads fixture `Event` JSON from `apps/colony_adapter_k8s/priv/fixtures/`,
  translates each payload to a canonical Colony event, and publishes onto
  `colony.agent.events` via `ColonyKafka.publish/2`.

  Usage:

      mix colony.adapter.k8s.replay --all
      mix colony.adapter.k8s.replay --fixture crashloop_payments
      mix colony.adapter.k8s.replay --list
      mix colony.adapter.k8s.replay --all --topic colony.agent.events

  Options:
    --all                 Replay every shipped fixture
    --fixture <slug>      Replay a single fixture by slug (filename without .json)
    --list                Print the shipped fixtures and exit
    --topic <topic>       Destination Kafka topic (default: colony.agent.events)

  See `docs/adr/0002-adapter-seam.md` for the input-adapter contract.
  """

  use Mix.Task

  alias ColonyAdapterK8s.{Fixtures, Replay}

  @default_topic "colony.agent.events"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          all: :boolean,
          fixture: :string,
          list: :boolean,
          topic: :string
        ]
      )

    if invalid != [] do
      Mix.shell().error("Unknown options: #{inspect(invalid)}")
      usage_error()
    end

    Mix.Task.run("app.start")

    cond do
      Keyword.get(opts, :list, false) ->
        print_fixtures()

      Keyword.has_key?(opts, :fixture) ->
        replay_one(Keyword.fetch!(opts, :fixture), opts)

      Keyword.get(opts, :all, false) ->
        replay_all(opts)

      true ->
        usage_error()
    end
  end

  defp print_fixtures do
    Mix.shell().info("Available ColonyAdapterK8s fixtures:")
    Enum.each(Fixtures.list(), fn name -> Mix.shell().info("  - #{name}") end)
  end

  defp replay_one(name, opts) do
    topic = Keyword.get(opts, :topic, @default_topic)
    Mix.shell().info("replaying fixture: #{name} → #{topic}")

    case Replay.replay_one(name, topic: topic) do
      {:ok, events} ->
        log_events(events, topic)

      {:error, reason} ->
        Mix.shell().error("replay failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp replay_all(opts) do
    topic = Keyword.get(opts, :topic, @default_topic)
    fixtures = Fixtures.list()

    if fixtures == [] do
      Mix.shell().error("no fixtures found in #{Fixtures.fixtures_dir()}")
      exit({:shutdown, 1})
    end

    Mix.shell().info("replaying #{length(fixtures)} fixtures → #{topic}")

    results = Replay.replay_all(topic: topic)

    failures =
      Enum.flat_map(results, fn
        {_name, {:ok, events}} ->
          log_events(events, topic)
          []

        {name, {:error, reason}} ->
          Mix.shell().error("  #{name}: #{inspect(reason)}")
          [{name, reason}]
      end)

    if failures != [] do
      Mix.shell().error("#{length(failures)} fixture(s) failed")
      exit({:shutdown, 1})
    end
  end

  defp log_events(events, topic) do
    Enum.each(events, fn event ->
      Mix.shell().info(
        "  #{event.id}  #{event.type}  subject=#{event.subject}  " <>
          "kind=#{event.data["kind"]}  → #{topic}"
      )
    end)
  end

  defp usage_error do
    Mix.shell().error(
      "Usage: mix colony.adapter.k8s.replay [--all | --fixture <slug> | --list] " <>
        "[--topic <topic>]"
    )

    exit({:shutdown, 1})
  end
end
