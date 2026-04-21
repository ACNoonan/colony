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

  @doc """
  Pure reasoning: call the LLM with role-appropriate tools and return the
  list of emit attrs the cell should publish. Side-effect-free — use this
  for dry-run previews and testing.
  """
  @spec plan(Event.t(), map(), Manifest.Cell.t()) ::
          {:ok, [map()], map()} | {:error, term()}
  def plan(%Event{} = trigger, projections, %Manifest.Cell{} = manifest_cell) do
    tools = Tools.for_role(manifest_cell.role)

    if tools == [] do
      {:ok, [], %{content: nil, tool_calls: [], stop_reason: :end_turn, usage: %{}}}
    else
      do_plan(trigger, projections, manifest_cell, tools)
    end
  end

  defp do_plan(trigger, projections, manifest_cell, tools) do
    system = Prompt.text_for(manifest_cell)
    user = build_user_content(trigger, projections)

    messages = [
      %{role: :system, content: system},
      %{role: :user, content: user}
    ]

    case LLM.call(messages, tools: tools) do
      {:ok, response} ->
        planned =
          response.tool_calls
          |> Enum.map(&tool_call_to_attrs(trigger, tools, &1))
          |> Enum.reject(&is_nil/1)

        {:ok, planned, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Full reasoning: plan + emit each resulting event through
  `ColonyCell.emit/3`. This is what `ColonyCell.Cell` schedules under
  `ColonyCell.TaskSupervisor` when a reasoning trigger fires.
  """
  @spec reason(binary(), Event.t(), map(), Manifest.Cell.t()) :: :ok
  def reason(cell_id, %Event{} = trigger, projections, %Manifest.Cell{} = manifest_cell) do
    case plan(trigger, projections, manifest_cell) do
      {:ok, [], _response} ->
        Logger.info("Reasoner: no tool calls for cell #{cell_id} on event #{trigger.id}")
        :ok

      {:ok, planned, _response} ->
        Enum.each(planned, &emit_planned(cell_id, &1))

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

  defp tool_call_to_attrs(%Event{} = trigger, tools, %{name: tool_name, arguments: args}) do
    case Enum.find(tools, &(&1.name == tool_name)) do
      nil ->
        Logger.warning(
          "Reasoner: LLM returned unknown tool name #{inspect(tool_name)}; skipping"
        )

        nil

      %{event_type: event_type} = tool ->
        %{
          id: "evt-reasoned-#{System.unique_integer([:positive])}",
          type: event_type,
          subject: trigger.subject,
          correlation_id: trigger.correlation_id,
          causation_id: trigger.id,
          tenant_id: trigger.tenant_id,
          swarm_id: trigger.swarm_id,
          data: stringify_keys(args),
          action_key: expand_action_key(Map.get(tool, :action_key), trigger, args)
        }
    end
  end

  @doc false
  def expand_action_key(nil, _trigger, _args), do: nil

  def expand_action_key(template, %Event{} = trigger, args) when is_binary(template) do
    template
    |> String.replace("{subject}", to_string(trigger.subject || ""))
    |> String.replace("{correlation_id}", to_string(trigger.correlation_id || ""))
    |> String.replace("{causation_id}", to_string(trigger.id || ""))
    |> expand_args(args)
  end

  defp expand_args(str, args) when is_map(args) do
    Regex.replace(~r/\{args\.([A-Za-z0-9_]+)\}/, str, fn _whole, key ->
      args
      |> Map.get(key, Map.get(args, String.to_atom(key), ""))
      |> to_string()
    end)
  end

  defp expand_args(str, _), do: str

  defp emit_planned(cell_id, attrs) do
    case ColonyCell.emit(cell_id, attrs) do
      :ok ->
        Logger.info("Reasoner: cell #{cell_id} emitted #{attrs.type}")

      {:error, reason} ->
        Logger.warning(
          "Reasoner emit failed for cell #{cell_id} (#{attrs.type}): #{inspect(reason)}"
        )
    end
  end

  defp stringify_keys(args) when is_map(args) do
    Map.new(args, fn {k, v} -> {to_string(k), v} end)
  end
end
