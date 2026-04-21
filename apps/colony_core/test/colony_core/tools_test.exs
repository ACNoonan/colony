defmodule ColonyCore.ToolsTest do
  use ExUnit.Case, async: true

  alias ColonyCore.Tools

  test "coordinator has at least mitigation.selected and incident.resolved" do
    tools = Tools.for_role("coordinator")
    names = Enum.map(tools, & &1.name)

    assert "mitigation.selected" in names
    assert "incident.resolved" in names
  end

  test "unknown role returns empty list" do
    assert Tools.for_role("ghost") == []
  end

  test "known?/2 reflects the registry" do
    assert Tools.known?("coordinator", "mitigation.selected")
    refute Tools.known?("coordinator", "deploy.completed")
    refute Tools.known?("ghost", "anything")
  end

  test "each tool has name/description/parameters with required fields" do
    for role <- Tools.roles(),
        tool <- Tools.for_role(role) do
      assert is_binary(tool.name) and tool.name != ""
      assert is_binary(tool.description) and tool.description != ""
      assert is_map(tool.parameters)
      assert tool.parameters.type == "object"
      assert is_map(tool.parameters.properties)
    end
  end
end
