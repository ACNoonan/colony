defmodule ColonyCell.Systems.GateAuditor do
  @moduledoc """
  Gate auditor system cell.

  Consumes `colony.runtime.gate.rejected` and maintains per-rule counters
  plus the most recent N rejections. Exposes a snapshot API so operator
  tools can read current state without touching Kafka.

  Like the runtime logger, this cell tolerates a cold broker: failed
  subscriptions log a warning rather than crashing the supervisor.
  """

  use GenServer

  require Logger

  alias ColonyCore.Event
  alias ColonyCore.Manifest

  @default_topic "colony.runtime.gate.rejected"
  @recent_limit 20

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(opts))
  end

  @spec snapshot(Manifest.Cell.t()) :: map()
  def snapshot(%Manifest.Cell{} = cell) do
    GenServer.call(via(cell: cell), :snapshot)
  end

  @impl true
  def init(opts) do
    cell = Keyword.fetch!(opts, :cell)
    topic = Keyword.get(opts, :topic, @default_topic)

    state = %{
      cell: cell,
      topic: topic,
      subscriber: nil,
      counters: %{},
      total: 0,
      recent: []
    }

    send(self(), :subscribe)
    {:ok, state}
  end

  @impl true
  def handle_info(:subscribe, state) do
    case subscribe(state) do
      {:ok, pid} ->
        Logger.info("gate.auditor subscribed to #{state.topic}")
        {:noreply, %{state | subscriber: pid}}

      {:error, :kafka_adapter_not_configured} ->
        Logger.debug("gate.auditor subscribe skipped: kafka adapter disabled")
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("gate.auditor subscribe failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snap = %{
      cell_id: state.cell.name,
      kind: :system,
      role: state.cell.role,
      topic: state.topic,
      total_rejections: state.total,
      rejections_by_rule: state.counters,
      recent: state.recent
    }

    {:reply, snap, state}
  end

  @impl true
  def handle_cast({:observed, %Event{} = event}, state) do
    rule = get_in(event.data, ["rule"]) || "unknown"
    counters = Map.update(state.counters, rule, 1, &(&1 + 1))

    recent =
      [summarize(event) | state.recent]
      |> Enum.take(@recent_limit)

    {:noreply, %{state | total: state.total + 1, counters: counters, recent: recent}}
  end

  defp subscribe(state) do
    auditor = self()

    handler = fn %Event{} = event ->
      GenServer.cast(auditor, {:observed, event})
      :ok
    end

    group_id = "colony-gate-auditor-#{System.unique_integer([:positive])}"
    ColonyKafka.subscribe(state.topic, handler: handler, group_id: group_id)
  end

  defp summarize(%Event{} = event) do
    %{
      event_id: event.id,
      rule: get_in(event.data, ["rule"]),
      origin_type: get_in(event.data, ["origin_type"]),
      origin_topic: get_in(event.data, ["origin_topic"]),
      gate_mode: get_in(event.data, ["gate_mode"]),
      recorded_at: event.recorded_at
    }
  end

  defp via(opts) do
    cell = Keyword.fetch!(opts, :cell)
    {:via, Registry, {registry_name(), {:system, cell.name}}}
  end

  defp registry_name do
    Application.fetch_env!(:colony_cell, :registry_name)
  end

  @doc false
  def child_spec_for(%Manifest.Cell{role: "gate_auditor"} = cell) do
    %{
      id: {__MODULE__, cell.name},
      start: {__MODULE__, :start_link, [[cell: cell]]},
      type: :worker,
      restart: :permanent
    }
  end
end
