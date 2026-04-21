defmodule ColonyCell.Cell do
  use GenServer

  require Logger

  alias ColonyCore.Event
  alias ColonyCore.Manifest
  alias ColonyCore.Prompt

  @moduledoc """
  Minimal replay-friendly cell process.

  Today this is a GenServer so the repo stays dependency-light. The
  interface is intentionally shaped so we can later swap the internals to
  Jido processes without rewriting the whole demo surface.

  A cell optionally carries a `:prototype` — the name of the manifest
  entry that declares this cell's kind, role, topic, partition scheme,
  and prompt. When a prototype is set, the cell loads and hashes the
  layered constitution+role prompt at init. The hash is stamped on every
  event the cell emits, and a dispatched event whose `prompt_hash`
  disagrees with the cell's current hash is flagged as prompt drift.
  """

  def start_link(opts) do
    cell_id = Keyword.fetch!(opts, :cell_id)
    GenServer.start_link(__MODULE__, opts, name: ColonyCell.via(cell_id))
  end

  @impl true
  def init(opts) do
    cell_id = Keyword.fetch!(opts, :cell_id)
    prototype = Keyword.get(opts, :prototype)
    manifest_cell = resolve_prototype(prototype)

    state =
      %{
        cell_id: cell_id,
        partition_value: partition_value_from(cell_id),
        kind: Keyword.get(opts, :kind, manifest_kind(manifest_cell) || :agent),
        prototype: prototype,
        prompt_hash: prompt_hash_for(manifest_cell),
        manifest_cell: manifest_cell,
        handled_events: MapSet.new(),
        applied_actions: MapSet.new(),
        last_sequence: 0,
        projections: %{},
        drift_events: 0
      }

    {:ok, state}
  end

  # A runtime cell_id may be either a bare partition value (legacy shape)
  # or "<role>:<partition>" (multi-role shape). The partition value is what
  # outbound events should carry as `partition_key` so they route back to
  # the right cells.
  defp partition_value_from(cell_id) do
    case String.split(cell_id, ":", parts: 2) do
      [_role, partition] -> partition
      [single] -> single
    end
  end

  @impl true
  def handle_call({:dispatch, %Event{} = event}, _from, state) do
    state = detect_drift(state, event)

    cond do
      MapSet.member?(state.handled_events, event.id) ->
        {:reply, {:ok, :duplicate}, state}

      event.action_key && MapSet.member?(state.applied_actions, event.action_key) ->
        {:reply, {:ok, :duplicate_action}, record_event(state, event)}

      true ->
        next_state =
          state
          |> record_event(event)
          |> record_action(event)
          |> project_event(event)

        maybe_reason(next_state, event)

        {:reply, {:ok, :accepted}, next_state}
    end
  end

  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      cell_id: state.cell_id,
      kind: state.kind,
      prototype: state.prototype,
      prompt_hash: state.prompt_hash,
      last_sequence: state.last_sequence,
      handled_events: MapSet.size(state.handled_events),
      applied_actions: MapSet.size(state.applied_actions),
      drift_events: state.drift_events,
      projections: state.projections
    }

    {:reply, snapshot, state}
  end

  def handle_call({:emit, attrs, opts}, _from, state) do
    {result, state} = do_emit(state, attrs, opts)
    {:reply, result, state}
  end

  defp resolve_prototype(nil), do: nil

  defp resolve_prototype(prototype) when is_binary(prototype) do
    manifest = Manifest.load()
    Manifest.fetch_cell!(manifest, prototype)
  rescue
    e ->
      Logger.warning("Cell prototype #{inspect(prototype)} not resolvable: #{Exception.message(e)}")
      nil
  end

  defp manifest_kind(nil), do: nil
  defp manifest_kind(%Manifest.Cell{kind: kind}), do: kind

  defp prompt_hash_for(nil), do: nil
  defp prompt_hash_for(%Manifest.Cell{} = cell), do: Prompt.hash_for(cell)

  defp detect_drift(state, %Event{prompt_hash: nil}), do: state
  defp detect_drift(%{prompt_hash: nil} = state, _event), do: state
  defp detect_drift(%{prompt_hash: current} = state, %Event{prompt_hash: current}), do: state

  defp detect_drift(state, %Event{prompt_hash: dispatched_hash, id: event_id} = event) do
    if same_role_source?(event, state) do
      Logger.warning(
        "cell #{state.cell_id} prompt drift: event #{event_id} " <>
          "was emitted under prompt_hash=#{truncate(dispatched_hash)} " <>
          "but cell is on #{truncate(state.prompt_hash)}"
      )

      %{state | drift_events: state.drift_events + 1}
    else
      # Cross-role event: different hash is expected by construction.
      state
    end
  end

  # Outbound events from ColonyCell.emit set source as "<prototype>.<partition>".
  # Drift is only meaningful when the source's prototype matches our own —
  # otherwise the hash mismatch is just two different roles carrying their
  # own constitution+role prompts.
  defp same_role_source?(%Event{source: source}, %{prototype: prototype})
       when is_binary(source) and is_binary(prototype) do
    case String.split(source, ".", parts: 2) do
      [^prototype | _] -> true
      _ -> false
    end
  end

  defp same_role_source?(_, _), do: false

  defp maybe_reason(%{manifest_cell: nil}, _event), do: :ok
  defp maybe_reason(%{manifest_cell: %Manifest.Cell{kind: :system}}, _event), do: :ok

  defp maybe_reason(%{manifest_cell: %Manifest.Cell{} = manifest_cell} = state, %Event{type: type} = event) do
    if type in manifest_cell.reasoning_triggers do
      Task.Supervisor.start_child(ColonyCell.TaskSupervisor, fn ->
        ColonyCell.Reasoner.reason(state.cell_id, event, state.projections, state.manifest_cell)
      end)
    end

    :ok
  end

  defp do_emit(state, attrs, opts) do
    attrs =
      attrs
      |> Map.put_new(:prompt_hash, state.prompt_hash)
      |> Map.put_new_lazy(:source, fn -> default_source(state) end)
      |> Map.put_new(:partition_key, state.partition_value)
      |> Map.put_new_lazy(:sequence, fn -> state.last_sequence + 1 end)

    action_key = Map.get(attrs, :action_key)

    cond do
      action_key && MapSet.member?(state.applied_actions, action_key) ->
        {{:ok, :duplicate_action}, state}

      true ->
        event = Event.new(attrs)
        topic = Keyword.get_lazy(opts, :topic, fn -> default_topic(state) end)

        case topic do
          nil ->
            {{:error, :no_topic}, state}

          _ ->
            case ColonyKafka.publish(topic, event, Keyword.take(opts, [:bypass_gate])) do
              :ok ->
                new_state =
                  state
                  |> update_last_sequence(event.sequence)
                  |> maybe_remember_action(action_key)

                {:ok, new_state}

              {:error, _} = err ->
                {err, state}
            end
        end
    end
  end

  defp update_last_sequence(state, nil), do: state

  defp update_last_sequence(state, seq) when is_integer(seq) do
    %{state | last_sequence: max(state.last_sequence, seq)}
  end

  defp maybe_remember_action(state, nil), do: state

  defp maybe_remember_action(state, action_key) do
    %{state | applied_actions: MapSet.put(state.applied_actions, action_key)}
  end

  defp default_source(%{manifest_cell: %Manifest.Cell{role: role}, partition_value: partition})
       when is_binary(role) do
    "#{role}.#{partition}"
  end

  defp default_source(%{prototype: nil, cell_id: cell_id}), do: "cell.#{cell_id}"

  defp default_source(%{prototype: prototype, partition_value: partition}) when is_binary(prototype) do
    "#{prototype}.#{partition}"
  end

  defp default_topic(%{manifest_cell: %Manifest.Cell{topic: topic}}), do: topic
  defp default_topic(_), do: nil

  defp truncate(nil), do: "-"
  defp truncate(hash) when is_binary(hash), do: String.slice(hash, 0, 12)

  defp record_event(state, %Event{} = event) do
    %{state | handled_events: MapSet.put(state.handled_events, event.id)}
  end

  defp record_action(state, %Event{action_key: nil}), do: state

  defp record_action(state, %Event{action_key: key}) do
    %{state | applied_actions: MapSet.put(state.applied_actions, key)}
  end

  defp project_event(state, %Event{subject: subject, sequence: sequence, data: data}) do
    projections = Map.update(state.projections, subject, [data], &[data | &1])

    %{state | projections: projections, last_sequence: max(sequence || 0, state.last_sequence)}
  end
end
