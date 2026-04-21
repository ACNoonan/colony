defmodule ColonyCore.LLM.Fixture do
  @moduledoc """
  Deterministic LLM adapter for tests.

  Fixtures are held in an Agent as a FIFO queue of pre-baked responses.
  Each `call/2` consumes the next one. Set up by tests with
  `set_fixtures/1` (or `push_fixture/1`).

      ColonyCore.LLM.Fixture.set_fixtures([
        %{content: nil, tool_calls: [%{id: "t1", name: "foo", arguments: %{}}],
          stop_reason: :tool_use, usage: %{input_tokens: 0, output_tokens: 0}}
      ])

  Returns `{:error, :fixture_exhausted}` when the queue runs out. Useful
  for catching tests that accidentally trigger more reasoning than
  expected.
  """

  @behaviour ColonyCore.LLM

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @spec set_fixtures([map()]) :: :ok
  def set_fixtures(fixtures) when is_list(fixtures) do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> fixtures end)
    :ok
  end

  @spec push_fixture(map()) :: :ok
  def push_fixture(fixture) when is_map(fixture) do
    ensure_started()
    Agent.update(__MODULE__, fn queue -> queue ++ [fixture] end)
    :ok
  end

  @spec remaining() :: non_neg_integer()
  def remaining do
    ensure_started()
    Agent.get(__MODULE__, &length/1)
  end

  @impl true
  def call(_messages, _opts) do
    ensure_started()

    Agent.get_and_update(__MODULE__, fn
      [] -> {{:error, :fixture_exhausted}, []}
      [next | rest] -> {{:ok, next}, rest}
    end)
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link([])
      _pid -> :ok
    end
  end
end
