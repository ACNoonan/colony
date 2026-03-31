defmodule ColonyKafka.Adapters.Unconfigured do
  @behaviour ColonyKafka

  @impl true
  def publish(_topic, _event) do
    {:error, :kafka_adapter_not_configured}
  end

  @impl true
  def subscribe(_topic, _opts) do
    {:error, :kafka_adapter_not_configured}
  end
end
