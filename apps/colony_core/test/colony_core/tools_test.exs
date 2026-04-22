defmodule ColonyCore.ToolsTest do
  use ExUnit.Case, async: true

  alias ColonyCore.Tools

  test "coordinator has tools that produce remediation.selected and episode.closed" do
    tools = Tools.for_role("coordinator")
    event_types = Enum.map(tools, & &1.event_type)

    assert "remediation.selected" in event_types
    assert "episode.closed" in event_types
  end

  test "specialist has a tool that produces remediation.proposed" do
    tools = Tools.for_role("specialist")
    assert Enum.any?(tools, &(&1.event_type == "remediation.proposed"))
    assert Tools.event_type_for("specialist", "propose_remediation") == "remediation.proposed"
  end

  test "unknown role returns empty list" do
    assert Tools.for_role("ghost") == []
  end

  test "known?/2 checks event types, not tool names" do
    assert Tools.known?("coordinator", "remediation.selected")
    refute Tools.known?("coordinator", "change.detected")
    refute Tools.known?("ghost", "anything")
  end

  test "event_type_for/2 maps tool slug to emitted event type" do
    assert Tools.event_type_for("coordinator", "select_remediation") == "remediation.selected"
    assert Tools.event_type_for("coordinator", "close_episode") == "episode.closed"
    assert Tools.event_type_for("coordinator", "unknown_tool") == nil
  end

  test "every tool name matches provider regex (no dots)" do
    for role <- Tools.roles(),
        tool <- Tools.for_role(role) do
      assert tool.name =~ ~r/^[a-zA-Z0-9_-]{1,128}$/,
             "tool #{inspect(tool.name)} for role #{role} breaks provider naming pattern"
    end
  end

  test "each tool has name/event_type/description/parameters" do
    for role <- Tools.roles(),
        tool <- Tools.for_role(role) do
      assert is_binary(tool.name) and tool.name != ""
      assert is_binary(tool.event_type) and tool.event_type != ""
      assert is_binary(tool.description) and tool.description != ""
      assert is_map(tool.parameters)
      assert tool.parameters.type == "object"
      assert is_map(tool.parameters.properties)
    end
  end
end
