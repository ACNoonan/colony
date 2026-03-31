defmodule ColonyKafka.Adapters.Brod do
  @behaviour ColonyKafka

  alias ColonyCore.Event

  @client :colony_kafka

  @impl true
  def publish(topic, %Event{} = event) do
    ensure_producer(topic)
    partition_key = event.partition_key || event.subject || event.id
    value = Event.encode!(event)

    case :brod.produce_sync(@client, topic, :hash, partition_key, value) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  defp ensure_producer(topic) do
    case :brod.start_producer(@client, topic, []) do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  @impl true
  def subscribe(topic, opts \\ []) do
    group_id = Keyword.get(opts, :group_id, "colony-#{topic}")
    handler = Keyword.fetch!(opts, :handler)

    config = %{
      client: @client,
      group_id: group_id,
      topics: [topic],
      cb_module: ColonyKafka.Consumer,
      init_data: %{handler: handler},
      message_type: :message,
      group_config: [
        offset_commit_policy: :commit_to_kafka_v2,
        offset_commit_interval_seconds: 5
      ],
      consumer_config: [begin_offset: :earliest]
    }

    :brod.start_link_group_subscriber_v2(config)
  end
end
