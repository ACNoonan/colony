defmodule Mix.Tasks.Colony.Reason do
  @shortdoc "Exercise reasoning on a Phase 1 incident-coordination scenario"

  @moduledoc """
  Exercises coordinator or specialist reasoning against a shipped **Phase 1**
  reference scenario (README capability ladder step 1). The positional
  argument is the remediation episode subject (`incident_id` in both current
  scenarios).

  Usage: mix colony.reason [incident_id] [options]

  Options:
    --scenario <name>     Which scenario fixture to use (default:
                          `change_failure`; also supports `canary_regression`)
    --role <role>         Which role to trigger (default: coordinator).
                          coordinator → remediation.proposed trigger
                          specialist  → blast_radius.assessed trigger
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

  alias ColonyCore.Manifest
  alias ColonyCell.Reasoner

  @default_role "coordinator"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          scenario: :string,
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

    scenario =
      opts |> Keyword.get(:scenario, ColonyDemo.default_scenario()) |> normalize_scenario!()

    incident = positional |> List.first() || default_episode_subject(scenario)
    role = Keyword.get(opts, :role, @default_role)
    strategy = Keyword.get(opts, :strategy, default_strategy(scenario))
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
    trigger = build_trigger(scenario, role, incident, strategy)
    projections = build_projections(scenario, role, incident, strategy)

    Mix.shell().info("scenario: #{scenario}")
    Mix.shell().info("episode:  #{incident}")
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

    snapshot_every_agent_cell(verbose)
  end

  defp snapshot_every_agent_cell(verbose) do
    entries =
      ColonyCell.Registry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1"}}]}])
      |> Enum.map(fn {cell_id} -> cell_id end)
      |> Enum.filter(&is_binary/1)
      |> Enum.sort()

    Mix.shell().info("")
    Mix.shell().info("cells spawned during this run: #{length(entries)}")

    Enum.each(entries, &print_snapshot(&1, verbose))
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

  defp build_trigger(scenario, role, incident, strategy) do
    scenario
    |> ColonyDemo.scenario_module!()
    |> apply(:reason_trigger, [role, incident, strategy])
  rescue
    e in ArgumentError ->
      Mix.shell().error(Exception.message(e))
      exit({:shutdown, 1})
  end

  defp build_projections(scenario, role, incident, strategy) do
    scenario
    |> ColonyDemo.scenario_module!()
    |> apply(:reason_projections, [role, incident, strategy])
  rescue
    _ -> %{}
  end

  defp default_episode_subject(scenario) do
    ColonyDemo.scenario_module!(scenario).default_episode_subject()
  end

  defp default_strategy(scenario) do
    ColonyDemo.scenario_module!(scenario).default_strategy()
  end

  defp normalize_scenario!(scenario) when is_atom(scenario),
    do: scenario |> Atom.to_string() |> normalize_scenario!()

  defp normalize_scenario!(scenario) when is_binary(scenario) do
    if scenario in ColonyDemo.available_scenarios() do
      scenario
    else
      Mix.shell().error(
        "Unknown scenario #{inspect(scenario)}. Available: #{inspect(ColonyDemo.available_scenarios())}"
      )

      exit({:shutdown, 1})
    end
  end
end
