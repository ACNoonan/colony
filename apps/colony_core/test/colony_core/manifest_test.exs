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
            prompt: "roles/coordinator.md",
            consumes: ["remediation.proposed"]
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

      assert [
               %Cell{name: "coordinator", kind: :agent},
               %Cell{name: "runtime.logger", kind: :system}
             ] =
               manifest.cells
    end

    test "rejects duplicate cell names" do
      raw = %{
        cells: [
          %{
            name: "a",
            kind: :agent,
            role: "r",
            topic: "t",
            partition_scheme: :single,
            prompt: "p.md"
          },
          %{
            name: "a",
            kind: :agent,
            role: "r",
            topic: "t",
            partition_scheme: :single,
            prompt: "p.md"
          }
        ]
      }

      assert_raise ArgumentError, ~r/duplicate cell name "a"/, fn ->
        Manifest.from_raw!(raw)
      end
    end

    test "rejects agent cell with no prompt" do
      raw = %{
        cells: [
          %{
            name: "a",
            kind: :agent,
            role: "r",
            topic: "t",
            partition_scheme: :single,
            prompt: nil
          }
        ]
      }

      assert_raise ArgumentError, ~r/agent cell "a" must declare a prompt path/, fn ->
        Manifest.from_raw!(raw)
      end
    end

    test "rejects system cell with a prompt" do
      raw = %{
        cells: [
          %{
            name: "a",
            kind: :system,
            role: "r",
            topic: "t",
            partition_scheme: :single,
            prompt: "p.md"
          }
        ]
      }

      assert_raise ArgumentError, ~r/system cell "a" must not declare a prompt/, fn ->
        Manifest.from_raw!(raw)
      end
    end

    test "rejects invalid kind" do
      raw = %{
        cells: [
          %{
            name: "a",
            kind: :daemon,
            role: "r",
            topic: "t",
            partition_scheme: :single,
            prompt: "p.md"
          }
        ]
      }

      assert_raise ArgumentError, ~r/invalid kind :daemon/, fn ->
        Manifest.from_raw!(raw)
      end
    end

    test "rejects invalid partition scheme" do
      raw = %{
        cells: [
          %{
            name: "a",
            kind: :agent,
            role: "r",
            topic: "t",
            partition_scheme: :nope,
            prompt: "p.md"
          }
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

  describe "consumes" do
    test "agent cells must declare non-empty consumes" do
      raw = %{
        cells: [
          %{
            name: "a",
            kind: :agent,
            role: "r",
            topic: "t",
            partition_scheme: :single,
            prompt: "p.md"
          }
        ]
      }

      assert_raise ArgumentError, ~r/must declare a non-empty `consumes`/, fn ->
        Manifest.from_raw!(raw)
      end
    end

    test "system cells must not declare consumes" do
      raw = %{
        cells: [
          %{
            name: "a",
            kind: :system,
            role: "logger",
            topic: "t",
            partition_scheme: :single,
            consumes: ["x"]
          }
        ]
      }

      assert_raise ArgumentError, ~r/must not declare `consumes`/, fn ->
        Manifest.from_raw!(raw)
      end
    end

    test "reasoning_triggers must be a subset of consumes" do
      raw = %{
        cells: [
          %{
            name: "a",
            kind: :agent,
            role: "r",
            topic: "t",
            partition_scheme: :single,
            prompt: "p.md",
            consumes: ["x.happened"],
            reasoning_triggers: ["y.happened"]
          }
        ]
      }

      assert_raise ArgumentError, ~r/reasoning_triggers.*aren't in its consumes/, fn ->
        Manifest.from_raw!(raw)
      end
    end
  end

  describe "consuming_cells/3" do
    test "returns only agent cells on topic that declare the event type" do
      manifest =
        Manifest.from_raw!(%{
          cells: [
            %{
              name: "coord",
              kind: :agent,
              role: "coordinator",
              topic: "t",
              partition_scheme: {:field, :subject},
              prompt: "p.md",
              consumes: ["remediation.proposed"]
            },
            %{
              name: "spec",
              kind: :agent,
              role: "specialist",
              topic: "t",
              partition_scheme: {:field, :subject},
              prompt: "p.md",
              consumes: ["blast_radius.assessed"]
            },
            %{
              name: "log",
              kind: :system,
              role: "logger",
              topic: "colony.runtime.log",
              partition_scheme: :single
            }
          ]
        })

      assert [%{name: "coord"}] = Manifest.consuming_cells(manifest, "t", "remediation.proposed")
      assert [%{name: "spec"}] = Manifest.consuming_cells(manifest, "t", "blast_radius.assessed")
      assert [] = Manifest.consuming_cells(manifest, "t", "unknown.type")
    end
  end

  describe "reasoning_triggers" do
    test "defaults to empty list" do
      raw = %{
        cells: [
          %{
            name: "a",
            kind: :agent,
            role: "r",
            topic: "t",
            partition_scheme: :single,
            prompt: "p.md",
            consumes: ["x.happened"]
          }
        ]
      }

      assert [%Cell{reasoning_triggers: []}] = Manifest.from_raw!(raw).cells
    end

    test "accepts a list of event type strings" do
      raw = %{
        cells: [
          %{
            name: "a",
            kind: :agent,
            role: "r",
            topic: "t",
            partition_scheme: :single,
            prompt: "p.md",
            consumes: ["x.happened", "y.happened"],
            reasoning_triggers: ["x.happened", "y.happened"]
          }
        ]
      }

      assert [%Cell{reasoning_triggers: ["x.happened", "y.happened"]}] =
               Manifest.from_raw!(raw).cells
    end

    test "rejects non-list values" do
      raw = %{
        cells: [
          %{
            name: "a",
            kind: :agent,
            role: "r",
            topic: "t",
            partition_scheme: :single,
            prompt: "p.md",
            reasoning_triggers: "x.happened"
          }
        ]
      }

      assert_raise ArgumentError, ~r/reasoning_triggers must be a list/, fn ->
        Manifest.from_raw!(raw)
      end
    end

    test "rejects empty strings inside the list" do
      raw = %{
        cells: [
          %{
            name: "a",
            kind: :agent,
            role: "r",
            topic: "t",
            partition_scheme: :single,
            prompt: "p.md",
            reasoning_triggers: ["ok", ""]
          }
        ]
      }

      assert_raise ArgumentError, ~r/reasoning_triggers entries must be non-empty/, fn ->
        Manifest.from_raw!(raw)
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

  describe "conflicting partition schemes on the same topic" do
    test "rejects manifests that disagree" do
      raw = %{
        cells: [
          %{
            name: "a",
            kind: :agent,
            role: "r1",
            topic: "shared",
            partition_scheme: {:field, :subject},
            prompt: "p.md",
            consumes: ["x"]
          },
          %{
            name: "b",
            kind: :agent,
            role: "r2",
            topic: "shared",
            partition_scheme: {:field, :tenant_id},
            prompt: "p.md",
            consumes: ["x"]
          }
        ]
      }

      assert_raise ArgumentError, ~r/conflicting partition schemes/, fn ->
        Manifest.from_raw!(raw)
      end
    end

    test "accepts identical schemes across multiple cells on a topic" do
      raw = %{
        cells: [
          %{
            name: "a",
            kind: :agent,
            role: "r1",
            topic: "shared",
            partition_scheme: {:field, :subject},
            prompt: "p.md",
            consumes: ["x"]
          },
          %{
            name: "b",
            kind: :agent,
            role: "r2",
            topic: "shared",
            partition_scheme: {:field, :subject},
            prompt: "p.md",
            consumes: ["x"]
          }
        ]
      }

      assert %Manifest{cells: [_, _]} = Manifest.from_raw!(raw)
    end
  end

  describe "partition_scheme_for!/2 and cell_id_for!/3" do
    setup do
      manifest =
        Manifest.from_raw!(%{
          cells: [
            %{
              name: "a",
              kind: :agent,
              role: "r",
              topic: "t1",
              partition_scheme: {:field, :subject},
              prompt: "p.md",
              consumes: ["x"]
            },
            %{
              name: "b",
              kind: :system,
              role: "logger",
              topic: "t2",
              partition_scheme: :single,
              prompt: nil
            }
          ]
        })

      {:ok, manifest: manifest}
    end

    test "returns the scheme for a known topic", %{manifest: manifest} do
      assert Manifest.partition_scheme_for!(manifest, "t1") == {:field, :subject}
      assert Manifest.partition_scheme_for!(manifest, "t2") == :single
    end

    test "raises for an unknown topic", %{manifest: manifest} do
      assert_raise ArgumentError, ~r/no declared cells/, fn ->
        Manifest.partition_scheme_for!(manifest, "ghost")
      end
    end

    test "routes by {:field, f}", %{manifest: manifest} do
      assert Manifest.cell_id_for!(manifest, "t1", %{subject: "incident-42"}) == "incident-42"
    end

    test "routes :single to the topic name", %{manifest: manifest} do
      assert Manifest.cell_id_for!(manifest, "t2", %{subject: "anything"}) == "t2"
    end

    test "raises when the partition field is missing", %{manifest: manifest} do
      assert_raise ArgumentError, ~r/event missing field :subject/, fn ->
        Manifest.cell_id_for!(manifest, "t1", %{})
      end
    end

    test "routes {:hash, f} to a deterministic string" do
      manifest =
        Manifest.from_raw!(%{
          cells: [
            %{
              name: "a",
              kind: :agent,
              role: "r",
              topic: "h",
              partition_scheme: {:hash, :tenant_id},
              prompt: "p.md",
              consumes: ["x"]
            }
          ]
        })

      id_a = Manifest.cell_id_for!(manifest, "h", %{tenant_id: "tenant-1"})
      id_b = Manifest.cell_id_for!(manifest, "h", %{tenant_id: "tenant-1"})
      id_c = Manifest.cell_id_for!(manifest, "h", %{tenant_id: "tenant-2"})

      assert id_a == id_b
      refute id_a == id_c
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
              prompt: "p.md",
              consumes: ["x"]
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
