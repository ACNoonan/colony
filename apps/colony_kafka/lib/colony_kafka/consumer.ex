defmodule ColonyKafka.Consumer do
  @moduledoc """
  Brod group subscriber callback that decodes events and dispatches them
  to a handler function.

  The handler receives the decoded `ColonyCore.Event` and returns `:ok`
  to commit the offset, or `{:error, reason}` to skip and log.
  """

  @behaviour :brod_group_subscriber_v2

  require Logger
  require Record

  alias ColonyCore.Event

  Record.defrecord(:kafka_message,
    Record.extract(:kafka_message, from_lib: "kafka_protocol/include/kpro_public.hrl")
  )

  @impl true
  def init(_group_id, %{handler: handler}) do
    {:ok, %{handler: handler}}
  end

  @impl true
  def handle_message(message, state) do
    value = kafka_message(message, :value)

    case Event.decode(value) do
      {:ok, event} ->
        case state.handler.(event) do
          :ok ->
            {:ok, :commit, state}

          {:ok, _} ->
            {:ok, :commit, state}

          {:error, reason} ->
            Logger.warning("Handler rejected event #{event.id}: #{inspect(reason)}")
            {:ok, :commit, state}
        end

      {:error, reason} ->
        Logger.error("Failed to decode event: #{inspect(reason)}")
        {:ok, :commit, state}
    end
  end
end
