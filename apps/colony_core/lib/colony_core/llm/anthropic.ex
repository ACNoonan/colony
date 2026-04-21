defmodule ColonyCore.LLM.Anthropic do
  @moduledoc """
  Anthropic Messages API adapter.

  Reads `api_key` and `model` from `config :colony_core, :llm_anthropic`.
  In runtime.exs these come from `ANTHROPIC_API_KEY` and
  `COLONY_ANTHROPIC_MODEL` respectively.
  """

  @behaviour ColonyCore.LLM

  @api_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"
  @default_model "claude-opus-4-7"
  @default_max_tokens 4096

  @impl true
  def call(messages, opts) do
    cfg = config()

    case cfg[:api_key] do
      nil -> {:error, :missing_api_key}
      "" -> {:error, :missing_api_key}
      key -> do_call(messages, opts, cfg, key)
    end
  end

  defp do_call(messages, opts, cfg, api_key) do
    model = Keyword.get(opts, :model) || cfg[:model] || @default_model
    max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
    tools = Keyword.get(opts, :tools, [])

    {system, conversation} = split_system(messages)

    body =
      %{
        model: model,
        max_tokens: max_tokens,
        messages: Enum.map(conversation, &format_message/1)
      }
      |> put_if(:system, system, not is_nil(system))
      |> put_if(:tools, Enum.map(tools, &format_tool/1), tools != [])

    Req.post(@api_url,
      headers: [
        {"x-api-key", api_key},
        {"anthropic-version", @api_version},
        {"content-type", "application/json"}
      ],
      json: body,
      receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
    )
    |> handle_response()
  end

  defp config, do: Application.get_env(:colony_core, :llm_anthropic, [])

  defp split_system(messages) do
    case Enum.split_with(messages, &(&1.role == :system)) do
      {[], rest} -> {nil, rest}
      {systems, rest} -> {systems |> Enum.map(& &1.content) |> Enum.join("\n\n"), rest}
    end
  end

  defp format_message(%{role: role, content: content}) when is_binary(content) do
    %{role: Atom.to_string(role), content: content}
  end

  defp format_tool(%{name: name, description: desc, parameters: params}) do
    %{name: name, description: desc, input_schema: params}
  end

  defp put_if(map, _k, _v, false), do: map
  defp put_if(map, k, v, _true), do: Map.put(map, k, v)

  defp handle_response({:ok, %{status: 200, body: body}}), do: {:ok, parse(body)}
  defp handle_response({:ok, %{status: status, body: body}}), do: {:error, {:http, status, body}}
  defp handle_response({:error, reason}), do: {:error, reason}

  defp parse(body) do
    blocks = body["content"] || []

    text =
      blocks
      |> Enum.filter(&(&1["type"] == "text"))
      |> Enum.map(& &1["text"])
      |> Enum.join("\n")

    tool_calls =
      blocks
      |> Enum.filter(&(&1["type"] == "tool_use"))
      |> Enum.map(fn b ->
        %{id: b["id"], name: b["name"], arguments: b["input"] || %{}}
      end)

    %{
      content: if(text == "", do: nil, else: text),
      tool_calls: tool_calls,
      stop_reason: stop_reason(body["stop_reason"]),
      usage: %{
        input_tokens: get_in(body, ["usage", "input_tokens"]) || 0,
        output_tokens: get_in(body, ["usage", "output_tokens"]) || 0
      }
    }
  end

  defp stop_reason("end_turn"), do: :end_turn
  defp stop_reason("max_tokens"), do: :max_tokens
  defp stop_reason("stop_sequence"), do: :stop_sequence
  defp stop_reason("tool_use"), do: :tool_use
  defp stop_reason(_), do: :unknown
end
