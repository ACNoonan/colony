defmodule ColonyCore.LLM.FixtureTest do
  use ExUnit.Case, async: false

  alias ColonyCore.LLM.Fixture

  setup do
    Fixture.set_fixtures([])
    :ok
  end

  test "returns queued fixtures in order" do
    a = %{content: "a", tool_calls: [], stop_reason: :end_turn, usage: %{input_tokens: 0, output_tokens: 0}}
    b = %{content: "b", tool_calls: [], stop_reason: :end_turn, usage: %{input_tokens: 0, output_tokens: 0}}

    Fixture.set_fixtures([a, b])

    assert {:ok, ^a} = Fixture.call([], [])
    assert {:ok, ^b} = Fixture.call([], [])
  end

  test "returns :fixture_exhausted when queue is empty" do
    assert {:error, :fixture_exhausted} = Fixture.call([], [])
  end

  test "push_fixture/1 appends to the queue" do
    Fixture.push_fixture(%{content: "x", tool_calls: [], stop_reason: :end_turn, usage: %{input_tokens: 0, output_tokens: 0}})
    assert Fixture.remaining() == 1
  end
end
