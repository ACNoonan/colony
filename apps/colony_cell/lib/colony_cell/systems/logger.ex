defmodule ColonyCell.Systems.Logger do
  @moduledoc """
  Runtime logger system cell.

  Subscribes to the agent event topic and republishes a compact summary
  onto `colony.runtime.log` so operators can tail the whole swarm in one
  stream. This is the colony analog of swarm-forge's logger pane that
  tails `agent_messages.log`.

  Intentionally tolerant of a cold kafka: subscribe/publish failures
  surface as warnings rather than crashes so a broker outage never takes
  down the cell supervisor.
  """

  use GenServer

  require Logger

  alias ColonyCore.Event
  alias ColonyCore.Manifest

  @source "system.logger"
  @log_topic "colony.runtime.log"
  @default_agent_topic "colony.agent.events"

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(opts))
  end

  @impl true
  def init(opts) do
    cell = Keyword.fetch!(opts, :cell)
    agent_topic = Keyword.get(opts, :agent_topic, @default_agent_topic)
    log_topic = Keyword.get(opts, :log_topic, @log_topic)

    state = %{cell: cell, agent_topic: agent_topic, log_topic: log_topic, subscriber: nil}
    send(self(), :subscribe)
    {:ok, state}
  end

  @impl true
  def handle_info(:subscribe, state) do
    case subscribe(state) do
      {:ok, pid} ->
        Logger.info("system.logger subscribed to #{state.agent_topic}")
        {:noreply, %{state | subscriber: pid}}

      {:error, :kafka_adapter_not_configured} ->
        Logger.debug("system.logger subscribe skipped: kafka adapter disabled")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("system.logger subscribe failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp subscribe(state) do
    handler = fn event -> handle_event(event, state) end
    group_id = "colony-system-logger-#{System.unique_integer([:positive])}"
    ColonyKafka.subscribe(state.agent_topic, handler: handler, group_id: group_id)
  end

  defp handle_event(%Event{type: "runtime." <> _}, _state) do
    :ok
  end

  defp handle_event(%Event{} = event, state) do
    summary = summary_event(event, state.log_topic)

    case ColonyKafka.publish(state.log_topic, summary) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("system.logger publish failed: #{inspect(reason)}")
        :ok
    end
  end

  defp summary_event(%Event{} = origin, log_topic) do
    Event.new(%{
      id: "evt-log-#{System.unique_integer([:positive])}",
      type: "runtime.logged",
      source: @source,
      subject: origin.id,
      partition_key: log_topic,
      correlation_id: origin.correlation_id,
      causation_id: origin.id,
      tenant_id: origin.tenant_id,
      swarm_id: origin.swarm_id,
      data: %{
        "origin_type" => origin.type,
        "origin_source" => origin.source,
        "origin_subject" => origin.subject,
        "origin_sequence" => origin.sequence,
        "origin_action_key" => origin.action_key
      }
    })
  end

  defp via(opts) do
    cell = Keyword.fetch!(opts, :cell)
    {:via, Registry, {registry_name(), {:system, cell.name}}}
  end

  defp registry_name do
    Application.fetch_env!(:colony_cell, :registry_name)
  end

  @doc false
  def child_spec_for(%Manifest.Cell{role: "logger"} = cell) do
    %{
      id: {__MODULE__, cell.name},
      start: {__MODULE__, :start_link, [[cell: cell]]},
      type: :worker,
      restart: :permanent
    }
  end
end
