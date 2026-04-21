defmodule ColonyCore.ManifestTest do
  use ExUnit.Case, async: false

  alias ColonyCore.Manifest
  alias ColonyCore.Manifest.Cell

  describe "from_raw!/1" do
    test "parses a valid manifest" do
      raw = %{
        cells: [
          %{
            name: "coordinator",
            kind: :agent,
            role: "coordinator",
            topic: "colony.agent.events",
            partition_scheme: {:field, :subject},
            prompt: "roles/coordinator.md"
          },
          %{
            name: "runtime.logger",
            kind: :system,
            role: "logger",
            topic: "colony.runtime.log",
            partition_scheme: :single,
            prompt: nil
          }
        ]
      }

      manifest = Manifest.from_raw!(raw)

      assert [%Cell{name: "coordinator", kind: :agent}, %Cell{name: "runtime.logger", kind: :system}] =
               manifest.cells
    end

    test "rejects duplicate cell names" do
      raw = %{
        cells: [
          %{name: "a", kind: :agent, role: "r", topic: "t", partition_scheme: :single, prompt: "p.md"},
          %{name: "a", kind: :agent, role: "r", topic: "t", partition_scheme: :single, prompt: "p.md"}
        ]
      }

      assert_raise ArgumentError, ~r/duplicate cell name "a"/, fn ->
        Manifest.from_raw!(raw)
      end
    end

    test "rejects agent cell with no prompt" do
      raw = %{
        cells: [
          %{name: "a", kind: :agent, role: "r", topic: "t", partition_scheme: :single, prompt: nil}
        ]
      }

      assert_raise ArgumentError, ~r/agent cell "a" must declare a prompt path/, fn ->
        Manifest.from_raw!(raw)
      end
    end

    test "rejects system cell with a prompt" do
      raw = %{
        cells: [
          %{name: "a", kind: :system, role: "r", topic: "t", partition_scheme: :single, prompt: "p.md"}
        ]
      }

      assert_raise ArgumentError, ~r/system cell "a" must not declare a prompt/, fn ->
        Manifest.from_raw!(raw)
      end
    end

    test "rejects invalid kind" do
      raw = %{
        cells: [
          %{name: "a", kind: :daemon, role: "r", topic: "t", partition_scheme: :single, prompt: "p.md"}
        ]
      }

      assert_raise ArgumentError, ~r/invalid kind :daemon/, fn ->
        Manifest.from_raw!(raw)
      end
    end

    test "rejects invalid partition scheme" do
      raw = %{
        cells: [
          %{name: "a", kind: :agent, role: "r", topic: "t", partition_scheme: :nope, prompt: "p.md"}
        ]
      }

      assert_raise ArgumentError, ~r/invalid partition_scheme :nope/, fn ->
        Manifest.from_raw!(raw)
      end
    end

    test "rejects empty cell list" do
      assert_raise ArgumentError, ~r/at least one cell/, fn ->
        Manifest.from_raw!(%{cells: []})
      end
    end
  end

  describe "load/1" do
    test "loads the shipped swarm/manifest.exs" do
      manifest = Manifest.load()

      assert length(manifest.cells) >= 1
      assert Enum.all?(manifest.cells, &match?(%Cell{}, &1))
      assert "coordinator" in Manifest.roles(manifest)
      assert "colony.agent.events" in Manifest.topics(manifest)
    end
  end

  describe "fetch_cell!/2" do
    setup do
      manifest =
        Manifest.from_raw!(%{
          cells: [
            %{
              name: "coordinator",
              kind: :agent,
              role: "coordinator",
              topic: "t",
              partition_scheme: :single,
              prompt: "p.md"
            }
          ]
        })

      {:ok, manifest: manifest}
    end

    test "returns the named cell", %{manifest: manifest} do
      assert %Cell{name: "coordinator"} = Manifest.fetch_cell!(manifest, "coordinator")
    end

    test "raises on unknown cell", %{manifest: manifest} do
      assert_raise ArgumentError, ~r/not declared in manifest/, fn ->
        Manifest.fetch_cell!(manifest, "ghost")
      end
    end
  end
end
