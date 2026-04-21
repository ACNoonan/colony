defmodule ColonyCore.LLM do
  @moduledoc """
  Provider-agnostic LLM interface.

  Callers build a list of messages and optional tool schemas. Each adapter
  translates to its provider's wire format and normalizes the response
  into a common shape so cells don't need to know which model answered.

  Response shape:

      %{
        content: binary() | nil,
        tool_calls: [%{id: binary(), name: binary(), arguments: map()}],
        stop_reason: :end_turn | :max_tokens | :tool_use | :stop_sequence | :unknown,
        usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}
      }

  The active adapter is configured via `config :colony_core, :llm_adapter`.
  Default is `ColonyCore.LLM.Anthropic`. Tests typically set
  `ColonyCore.LLM.Fixture` and prime responses in advance.
  """

  @type role :: :system | :user | :assistant
  @type message :: %{role: role(), content: binary()}
  @type tool :: %{name: binary(), description: binary(), parameters: map()}

  @type response :: %{
          content: binary() | nil,
          tool_calls: [%{id: binary(), name: binary(), arguments: map()}],
          stop_reason: atom(),
          usage: %{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}
        }

  @callback call([message()], keyword()) :: {:ok, response()} | {:error, term()}

  @spec call([message()], keyword()) :: {:ok, response()} | {:error, term()}
  def call(messages, opts \\ []) do
    adapter().call(messages, opts)
  end

  @spec adapter() :: module()
  def adapter do
    Application.get_env(:colony_core, :llm_adapter, ColonyCore.LLM.Anthropic)
  end
end
