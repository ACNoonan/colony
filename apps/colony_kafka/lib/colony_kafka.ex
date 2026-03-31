defmodule ColonyKafka do
  @moduledoc """
  Kafka boundary for the swarm runtime.

  The runtime value proposition depends on Kafka being a first-class event log,
  not just a transport adapter hidden under higher-level abstractions.
  """

  alias ColonyCore.Event

  @callback publish(topic :: binary(), event :: Event.t()) :: :ok | {:error, term()}
  @callback subscribe(topic :: binary(), opts :: keyword()) :: :ok | {:error, term()}

  def publish(topic, %Event{} = event) when is_binary(topic) do
    adapter().publish(topic, event)
  end

  def subscribe(topic, opts \\ []) when is_binary(topic) do
    adapter().subscribe(topic, opts)
  end

  def adapter do
    Application.fetch_env!(:colony_kafka, :adapter)
  end
end
