defmodule ColonyAdapterK8s.Replay do
  @moduledoc """
  Drives the adapter end-to-end: load a fixture, translate it into canonical
  events, and publish onto a Kafka topic via `ColonyKafka.publish/2`.

  The replayer keeps no state across runs. A per-run cursor (the fixture
  slug) lives only in the caller's arguments — see ADR-0002's
  stateless-translator rule.
  """

  alias ColonyAdapterK8s.{Events, Fixtures}
  alias ColonyCore.Event

  @default_topic "colony.agent.events"

  @type publisher :: (binary(), Event.t() -> :ok | {:error, term()})
  @type replay_result :: {:ok, [Event.t()]} | {:error, term()}

  @doc """
  Replay every fixture in the shipped corpus.

  Returns a list of `{fixture_slug, replay_result()}` pairs, in the order
  they were processed.
  """
  @spec replay_all(keyword()) :: [{binary(), replay_result()}]
  def replay_all(opts \\ []) do
    Enum.map(Fixtures.list(), fn name ->
      {name, replay_one(name, opts)}
    end)
  end

  @doc """
  Replay a single fixture by slug.
  """
  @spec replay_one(binary(), keyword()) :: replay_result()
  def replay_one(name, opts \\ []) when is_binary(name) do
    topic = Keyword.get(opts, :topic, @default_topic)
    publisher = Keyword.get(opts, :publisher, &ColonyKafka.publish/2)

    with {:ok, payload} <- Fixtures.load(name),
         events = Events.translate(payload),
         :ok <- publish_all(topic, events, publisher) do
      {:ok, events}
    end
  end

  defp publish_all(topic, events, publisher) do
    Enum.reduce_while(events, :ok, fn event, _acc ->
      case publisher.(topic, event) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end
end
