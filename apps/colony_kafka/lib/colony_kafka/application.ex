defmodule ColonyKafka.Application do
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    brokers = Application.fetch_env!(:colony_kafka, :brokers)
    client_config = Application.get_env(:colony_kafka, :client_config, [])

    children =
      if Application.fetch_env!(:colony_kafka, :adapter) == ColonyKafka.Adapters.Brod do
        [
          %{
            id: :colony_kafka_client,
            start: {:brod, :start_link_client, [brokers, :colony_kafka, client_config]},
            type: :worker
          }
        ]
      else
        []
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
  end
end
