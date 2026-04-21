defmodule ColonyCell.Reasoner do
  @moduledoc """
  Turns a dispatched event into zero or more outbound events via an LLM.

  The reasoner runs inside a short-lived Task (see
  `ColonyCell.TaskSupervisor`) spawned by the cell on a configured event
  type. It:

    1. Loads the cell's layered constitution+role prompt as the system
       message.
    2. Summarizes the triggering event and cell projection as the user
       message.
    3. Calls the configured LLM with the role's tool schemas
       (`ColonyCore.Tools.for_role/1`).
    4. For each tool call in the response, emits a matching
       `ColonyCore.Event` via `ColonyCell.emit/3`. `prompt_hash`,
       `correlation_id`, `causation_id`, and lineage fields are carried
       over from the trigger.

  Failures are logged and swallowed. The cell's projection already
  recorded the triggering event; replay will rebuild state without
  re-reasoning (model A: stream is truth, LLM is only a decision source).
  """

  require Logger

  alias ColonyCore.Event
  alias ColonyCore.LLM
  alias ColonyCore.Manifest
  alias ColonyCore.Prompt
  alias ColonyCore.Tools

  @spec reason(binary(), Event.t(), map(), Manifest.Cell.t()) :: :ok
  def reason(cell_id, %Event{} = trigger, projections, %Manifest.Cell{} = manifest_cell) do
    role = manifest_cell.role
    tools = Tools.for_role(role)

    if tools == [] do
      Logger.debug("Reasoner: no tools for role #{role}, skipping")
      :ok
    else
      do_reason(cell_id, trigger, projections, manifest_cell, tools)
    end
  end

  defp do_reason(cell_id, trigger, projections, manifest_cell, tools) do
    system = Prompt.text_for(manifest_cell)
    user = build_user_content(trigger, projections)

    messages = [
      %{role: :system, content: system},
      %{role: :user, content: user}
    ]

    case LLM.call(messages, tools: tools) do
      {:ok, %{tool_calls: []}} ->
        Logger.info("Reasoner: no tool calls for cell #{cell_id} on event #{trigger.id}")
        :ok

      {:ok, %{tool_calls: calls}} ->
        Enum.each(calls, &emit_tool_call(cell_id, trigger, &1))

      {:error, reason} ->
        Logger.warning(
          "Reasoner LLM call failed for cell #{cell_id} (event #{trigger.id}): #{inspect(reason)}"
        )
    end
  end

  defp build_user_content(%Event{} = trigger, projections) do
    """
    A new event just arrived for this cell. Decide what, if anything, to
    emit in response.

    ## Triggering event
    type: #{trigger.type}
    id: #{trigger.id}
    subject: #{trigger.subject}
    source: #{trigger.source}
    causation_id: #{trigger.causation_id}
    correlation_id: #{trigger.correlation_id}
    data: #{inspect(trigger.data, pretty: true)}

    ## Cell projection (events this cell has already handled, by subject)
    #{format_projections(projections)}

    Use only the tools available to you. If no action is warranted right
    now, call no tools.
    """
  end

  defp format_projections(projections) when map_size(projections) == 0, do: "(empty)"

  defp format_projections(projections) do
    projections
    |> Enum.map(fn {subject, events_data} ->
      "- #{subject}: #{length(events_data)} past events\n" <>
        Enum.map_join(events_data, "\n", fn data -> "  - " <> inspect(data) end)
    end)
    |> Enum.join("\n")
  end

  defp emit_tool_call(cell_id, %Event{} = trigger, %{name: event_type, arguments: args}) do
    attrs = %{
      id: "evt-reasoned-#{System.unique_integer([:positive])}",
      type: event_type,
      subject: trigger.subject,
      correlation_id: trigger.correlation_id,
      causation_id: trigger.id,
      tenant_id: trigger.tenant_id,
      swarm_id: trigger.swarm_id,
      data: stringify_keys(args)
    }

    case ColonyCell.emit(cell_id, attrs) do
      :ok ->
        Logger.info("Reasoner: cell #{cell_id} emitted #{event_type}")

      {:error, reason} ->
        Logger.warning(
          "Reasoner emit failed for cell #{cell_id} (#{event_type}): #{inspect(reason)}"
        )
    end
  end

  defp stringify_keys(args) when is_map(args) do
    Map.new(args, fn {k, v} -> {to_string(k), v} end)
  end
end
