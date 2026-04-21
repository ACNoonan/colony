defmodule ColonyCore.LLM.OpenAI do
  @moduledoc """
  OpenAI Chat Completions adapter with tool use.

  Reads `api_key` and `model` from `config :colony_core, :llm_openai`.
  """

  @behaviour ColonyCore.LLM

  @api_url "https://api.openai.com/v1/chat/completions"
  @default_model "gpt-4o"

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
    tools = Keyword.get(opts, :tools, [])

    body =
      %{
        model: model,
        messages: Enum.map(messages, &format_message/1)
      }
      |> put_if(:tools, Enum.map(tools, &format_tool/1), tools != [])

    Req.post(@api_url,
      headers: [
        {"authorization", "Bearer " <> api_key},
        {"content-type", "application/json"}
      ],
      json: body,
      receive_timeout: Keyword.get(opts, :receive_timeout, 30_000)
    )
    |> handle_response()
  end

  defp config, do: Application.get_env(:colony_core, :llm_openai, [])

  defp format_message(%{role: role, content: content}) when is_binary(content) do
    %{role: Atom.to_string(role), content: content}
  end

  defp format_tool(%{name: name, description: desc, parameters: params}) do
    %{
      type: "function",
      function: %{name: name, description: desc, parameters: params}
    }
  end

  defp put_if(map, _k, _v, false), do: map
  defp put_if(map, k, v, _true), do: Map.put(map, k, v)

  defp handle_response({:ok, %{status: 200, body: body}}), do: {:ok, parse(body)}
  defp handle_response({:ok, %{status: status, body: body}}), do: {:error, {:http, status, body}}
  defp handle_response({:error, reason}), do: {:error, reason}

  defp parse(body) do
    choice = body["choices"] |> List.first() || %{}
    message = choice["message"] || %{}
    content = message["content"]

    tool_calls =
      (message["tool_calls"] || [])
      |> Enum.map(fn tc ->
        fn_block = tc["function"] || %{}
        args = decode_args(fn_block["arguments"])
        %{id: tc["id"], name: fn_block["name"], arguments: args}
      end)

    %{
      content: content,
      tool_calls: tool_calls,
      stop_reason: finish_reason(choice["finish_reason"]),
      usage: %{
        input_tokens: get_in(body, ["usage", "prompt_tokens"]) || 0,
        output_tokens: get_in(body, ["usage", "completion_tokens"]) || 0
      }
    }
  end

  defp decode_args(nil), do: %{}
  defp decode_args(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end
  defp decode_args(other) when is_map(other), do: other

  defp finish_reason("stop"), do: :end_turn
  defp finish_reason("length"), do: :max_tokens
  defp finish_reason("tool_calls"), do: :tool_use
  defp finish_reason("content_filter"), do: :stop_sequence
  defp finish_reason(_), do: :unknown
end
