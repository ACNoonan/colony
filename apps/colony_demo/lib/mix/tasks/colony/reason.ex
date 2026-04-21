defmodule Mix.Tasks.Colony.Reason do
  @shortdoc "Exercise the coordinator reasoning loop end-to-end"

  @moduledoc """
  Usage: mix colony.reason [incident_id] [options]

  Options:
    --role <role>         Which role to trigger (default: coordinator).
                          coordinator → mitigation.proposed trigger
                          specialist  → incident.triaged trigger
    --strategy <name>     Strategy for the fake proposal (default: rollback;
                          only used by the coordinator path)
    --dispatch            Start a real cell, dispatch the trigger, and wait
                          for the reasoner's emits to hit Kafka. Requires
                          a running broker and valid API key. Default is
                          a pure dry-run that only calls the LLM.
    --verbose             Print the full LLM response (stop_reason, usage,
                          tool_calls).

  Dry-run (default) makes a single real LLM call with the live adapter
  and prints the events the reasoner WOULD emit. Nothing touches Kafka
  and no cell process is started. Good for validating the LLM adapter
  against a live provider.

  With --dispatch, the task starts a prototype-aware cell, dispatches
  the synthetic trigger through the normal path, and prints the cell's
  snapshot after a short wait. Requires `make up` and sourced API keys.
  """

  use Mix.Task

  alias ColonyCore.Event
  alias ColonyCore.Manifest
  alias ColonyCell.Reasoner

  @default_incident "incident-042"
  @default_role "coordinator"
  @default_strategy "rollback"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          role: :string,
          strategy: :string,
          dispatch: :boolean,
          verbose: :boolean
        ]
      )

    if invalid != [] do
      Mix.shell().error("Unknown options: #{inspect(invalid)}")
      exit({:shutdown, 1})
    end

    incident = positional |> List.first() || @default_incident
    role = Keyword.get(opts, :role, @default_role)
    strategy = Keyword.get(opts, :strategy, @default_strategy)
    dispatch = Keyword.get(opts, :dispatch, false)
    verbose = Keyword.get(opts, :verbose, false)

    # Plan-mode never touches Kafka. Set the env var that runtime.exs
    # reads to override the adapter to Unconfigured, so brod doesn't spin
    # up and spam connection refused during app.start.
    unless dispatch do
      System.put_env("COLONY_DISABLE_KAFKA", "1")
    end

    Mix.Task.run("app.start")

    manifest = Manifest.load()
    cell = fetch_cell_for_role!(manifest, role)
    trigger = build_trigger(role, incident, strategy)
    projections = build_projections(role, incident, strategy)

    Mix.shell().info("incident: #{incident}")
    Mix.shell().info("role:     #{cell.role}  (manifest: #{cell.name})")
    Mix.shell().info("adapter:  #{inspect(ColonyCore.LLM.adapter())}")

    if dispatch do
      run_dispatch(incident, cell, trigger, verbose)
    else
      run_plan(trigger, projections, cell, verbose)
    end
  end

  defp fetch_cell_for_role!(manifest, role) do
    case Enum.find(Manifest.cells(manifest), &(&1.kind == :agent and &1.role == role)) do
      nil ->
        Mix.shell().error("No agent cell with role #{inspect(role)} in the manifest")
        exit({:shutdown, 1})

      cell ->
        cell
    end
  end

  defp run_plan(trigger, projections, cell, verbose) do
    Mix.shell().info("mode: plan (dry-run)")
    Mix.shell().info("")

    case Reasoner.plan(trigger, projections, cell) do
      {:ok, [], response} ->
        Mix.shell().info("LLM returned no tool calls (stop_reason=#{response.stop_reason}).")
        maybe_print_response(response, verbose)

      {:ok, planned, response} ->
        Mix.shell().info("LLM proposed #{length(planned)} emit(s):")

        Enum.each(planned, fn attrs ->
          Mix.shell().info("")
          Mix.shell().info("  type: #{attrs.type}")
          Mix.shell().info("  subject: #{attrs.subject}")
          Mix.shell().info("  causation_id: #{attrs.causation_id}")
          Mix.shell().info("  data: #{inspect(attrs.data, pretty: true)}")
        end)

        maybe_print_response(response, verbose)

      {:error, reason} ->
        Mix.shell().error("")
        Mix.shell().error("LLM call failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  defp run_dispatch(incident, cell, trigger, verbose) do
    Mix.shell().info("mode: dispatch (live, requires kafka + api key)")
    Mix.shell().info("")

    # Start the umbrella consumer so events emitted by the triggered cell
    # route to the next cell in the chain (e.g. specialist → coordinator).
    ColonyDemo.ensure_topic()
    ColonyDemo.start_consumer()
    Process.sleep(2_000)

    {:ok, runtime_id} = ColonyCell.start_for(cell, incident)
    {:ok, status} = ColonyCell.dispatch(runtime_id, trigger)
    Mix.shell().info("dispatch → #{runtime_id}: #{status}")
    Mix.shell().info("waiting 20s for reasoners...")
    Process.sleep(20_000)

    print_snapshot(runtime_id, verbose)
    print_all_cells()
  end

  defp print_snapshot(runtime_id, verbose) do
    snap = ColonyCell.snapshot(runtime_id)
    Mix.shell().info("")
    Mix.shell().info("snapshot #{runtime_id}:")
    Mix.shell().info("  handled_events:  #{snap.handled_events}")
    Mix.shell().info("  applied_actions: #{snap.applied_actions}")
    Mix.shell().info("  drift_events:    #{snap.drift_events}")
    Mix.shell().info("  last_sequence:   #{snap.last_sequence}")
    Mix.shell().info("  prompt_hash:     #{String.slice(snap.prompt_hash || "", 0, 12)}")

    if verbose do
      Mix.shell().info("  projections: #{inspect(snap.projections, pretty: true)}")
    end
  end

  defp print_all_cells do
    entries =
      ColonyCell.Registry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1"}}]}])
      |> Enum.map(fn {cell_id} -> cell_id end)
      |> Enum.filter(&is_binary/1)
      |> Enum.sort()

    Mix.shell().info("")
    Mix.shell().info("all cells: #{inspect(entries)}")
  end

  defp maybe_print_response(_response, false), do: :ok

  defp maybe_print_response(response, true) do
    Mix.shell().info("")
    Mix.shell().info("raw response:")
    Mix.shell().info("  stop_reason: #{response.stop_reason}")
    Mix.shell().info("  usage: #{inspect(response.usage)}")
    Mix.shell().info("  content: #{inspect(response.content)}")

    if response.tool_calls != [] do
      Mix.shell().info("  tool_calls:")

      Enum.each(response.tool_calls, fn call ->
        Mix.shell().info("    - #{call.name}: #{inspect(call.arguments)}")
      end)
    end
  end

  defp build_trigger("coordinator", incident, strategy) do
    Event.new(%{
      id: "evt-proposed-#{strategy}-#{System.unique_integer([:positive])}",
      type: "mitigation.proposed",
      source: "specialist.#{strategy}",
      subject: incident,
      partition_key: incident,
      correlation_id: "corr-#{incident}",
      causation_id: "evt-triaged-#{incident}",
      tenant_id: "tenant-acme",
      swarm_id: "incident-response",
      sequence: 9,
      data: %{
        "strategy" => strategy,
        "target_version" => "v2.3.4",
        "estimated_recovery_seconds" => 90
      }
    })
  end

  defp build_trigger("specialist", incident, _strategy) do
    Event.new(%{
      id: "evt-triaged-#{System.unique_integer([:positive])}",
      type: "incident.triaged",
      source: "coordinator.triage",
      subject: incident,
      partition_key: incident,
      correlation_id: "corr-#{incident}",
      causation_id: "evt-opened-#{incident}",
      tenant_id: "tenant-acme",
      swarm_id: "incident-response",
      sequence: 8,
      data: %{
        "severity" => "high",
        "total_affected_endpoints" => 7,
        "candidate_mitigations" => ["rollback", "schema_shim"]
      }
    })
  end

  defp build_trigger(role, _incident, _strategy) do
    Mix.shell().error("No canned trigger for role #{inspect(role)}")
    exit({:shutdown, 1})
  end

  defp build_projections("coordinator", incident, strategy) do
    %{
      incident => [
        %{
          "type" => "mitigation.proposed",
          "strategy" => strategy,
          "estimated_recovery_seconds" => 90
        },
        %{
          "type" => "mitigation.proposed",
          "strategy" => "schema_shim",
          "estimated_recovery_seconds" => 300
        },
        %{
          "type" => "incident.triaged",
          "severity" => "high",
          "candidate_mitigations" => [strategy, "schema_shim"]
        },
        %{"type" => "incident.opened", "service" => "checkout-svc"}
      ]
    }
  end

  defp build_projections("specialist", incident, _strategy) do
    %{
      incident => [
        %{
          "type" => "incident.triaged",
          "severity" => "high",
          "candidate_mitigations" => ["rollback", "schema_shim"]
        },
        %{"type" => "incident.opened", "service" => "checkout-svc"}
      ]
    }
  end

  defp build_projections(_role, _incident, _strategy), do: %{}
end
