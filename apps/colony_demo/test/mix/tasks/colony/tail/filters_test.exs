defmodule Mix.Tasks.Colony.Tail.FiltersTest do
  use ExUnit.Case, async: true

  alias ColonyCore.Event
  alias Mix.Tasks.Colony.Tail.Filters

  defp event(overrides \\ %{}) do
    Event.new(
      Map.merge(
        %{
          id: "evt-1",
          type: "demo.happened",
          source: "specialist.incident-042",
          subject: "incident-042",
          partition_key: "incident-042",
          data: %{},
          correlation_id: "corr-42",
          causation_id: "corr-42"
        },
        overrides
      )
    )
  end

  describe "build/1" do
    test "keeps only present keys" do
      assert [cell: "x", role: "r"] = Filters.build(cell: "x", role: "r")
    end

    test "drops nil values" do
      assert [] == Filters.build(cell: nil, role: nil)
    end

    test "ignores unknown keys" do
      assert [cell: "x"] = Filters.build(cell: "x", mystery: "y")
    end
  end

  describe "format/1" do
    test "\"none\" for empty list" do
      assert Filters.format([]) == "none"
    end

    test "joins key=value pairs" do
      assert Filters.format(cell: "x", role: "r") == "cell=x,role=r"
    end
  end

  describe "passes?/2" do
    test "empty filter list passes everything" do
      assert Filters.passes?(event(), [])
    end

    test "composite filters are all-AND" do
      e = event(%{subject: "incident-042", source: "specialist.incident-042"})

      assert Filters.passes?(e, cell: "incident-042", role: "specialist")
      refute Filters.passes?(e, cell: "incident-042", role: "coordinator")
    end
  end

  describe "cell filter" do
    test "matches on subject" do
      assert Filters.passes?(event(%{subject: "inc-1"}), cell: "inc-1")
    end

    test "matches on partition_key" do
      assert Filters.passes?(event(%{subject: "x", partition_key: "inc-1"}), cell: "inc-1")
    end

    test "matches on data.origin_subject (runtime.logged envelope)" do
      e =
        event(%{
          type: "runtime.logged",
          subject: "evt-inner",
          partition_key: "colony.runtime.log",
          data: %{"origin_subject" => "inc-1"}
        })

      assert Filters.passes?(e, cell: "inc-1")
    end

    test "rejects when no candidate matches" do
      refute Filters.passes?(event(%{subject: "other"}), cell: "inc-1")
    end
  end

  describe "role filter" do
    test "matches on source prefix before the first dot" do
      assert Filters.passes?(event(%{source: "specialist.incident-042"}), role: "specialist")
      refute Filters.passes?(event(%{source: "coordinator.incident-042"}), role: "specialist")
    end

    test "matches on data.origin_source (runtime.logged envelope)" do
      e =
        event(%{
          type: "runtime.logged",
          source: "system.logger",
          data: %{"origin_source" => "specialist.incident-042"}
        })

      assert Filters.passes?(e, role: "specialist")
    end

    test "does not treat a longer role name as a false match" do
      assert Filters.passes?(event(%{source: "specialist.incident-042"}), role: "specialist")
      refute Filters.passes?(event(%{source: "specialists.incident-042"}), role: "specialist")
    end

    test "sources without a dot don't match" do
      refute Filters.passes?(event(%{source: "cd"}), role: "cd")
    end
  end

  describe "correlation filter" do
    test "exact match on correlation_id" do
      assert Filters.passes?(event(%{correlation_id: "corr-X"}), correlation: "corr-X")
      refute Filters.passes?(event(%{correlation_id: "corr-X"}), correlation: "corr-Y")
    end
  end
end
