defmodule ColonyCore.PromptTest do
  use ExUnit.Case, async: false

  alias ColonyCore.Manifest.Cell
  alias ColonyCore.Prompt

  setup do
    dir = Path.join(System.tmp_dir!(), "colony_prompt_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "roles"))
    File.write!(Path.join(dir, "constitution.md"), "CONSTITUTION\n")
    File.write!(Path.join([dir, "roles", "coordinator.md"]), "COORDINATOR\n")

    original = Application.get_env(:colony_core, :swarm_dir)
    Application.put_env(:colony_core, :swarm_dir, dir)

    on_exit(fn ->
      if original,
        do: Application.put_env(:colony_core, :swarm_dir, original),
        else: Application.delete_env(:colony_core, :swarm_dir)

      File.rm_rf!(dir)
    end)

    :ok
  end

  describe "text_for/1" do
    test "concatenates constitution and role for agent cells" do
      cell = %Cell{
        name: "coordinator",
        kind: :agent,
        role: "coordinator",
        topic: "t",
        partition_scheme: :single,
        prompt: "roles/coordinator.md"
      }

      text = Prompt.text_for(cell)
      assert text =~ "CONSTITUTION"
      assert text =~ "COORDINATOR"
      assert text =~ "---"
    end

    test "returns empty string for system cells" do
      cell = %Cell{
        name: "logger",
        kind: :system,
        role: "logger",
        topic: "t",
        partition_scheme: :single,
        prompt: nil
      }

      assert Prompt.text_for(cell) == ""
    end
  end

  describe "hash_for/1" do
    test "is deterministic for the same cell" do
      cell = %Cell{
        name: "coordinator",
        kind: :agent,
        role: "coordinator",
        topic: "t",
        partition_scheme: :single,
        prompt: "roles/coordinator.md"
      }

      assert Prompt.hash_for(cell) == Prompt.hash_for(cell)
    end

    test "is nil for system cells" do
      cell = %Cell{
        name: "logger",
        kind: :system,
        role: "logger",
        topic: "t",
        partition_scheme: :single,
        prompt: nil
      }

      assert Prompt.hash_for(cell) == nil
    end

    test "changes when the constitution changes" do
      cell = %Cell{
        name: "coordinator",
        kind: :agent,
        role: "coordinator",
        topic: "t",
        partition_scheme: :single,
        prompt: "roles/coordinator.md"
      }

      before = Prompt.hash_for(cell)

      File.write!(
        Path.join(Application.fetch_env!(:colony_core, :swarm_dir), "constitution.md"),
        "CHANGED\n"
      )

      refute Prompt.hash_for(cell) == before
    end
  end

  describe "hash/1" do
    test "produces a 64-character lowercase hex digest" do
      digest = Prompt.hash("hello")
      assert String.length(digest) == 64
      assert digest == String.downcase(digest)
      assert digest =~ ~r/^[0-9a-f]+$/
    end
  end
end
