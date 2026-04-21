defmodule Mix.Tasks.Colony.Reason do
  @shortdoc "Exercise the coordinator reasoning loop end-to-end"

  @moduledoc """
  Usage: mix colony.reason [incident_id] [options]

  Options:
    --prototype <name>    Manifest cell prototype to use (default: coordinator)
    --strategy <name>     Strategy for the first fake proposal (default: rollback)
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
  @default_prototype "coordinator"
  @default_strategy "rollback"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          prototype: :string,
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
    prototype = Keyword.get(opts, :prototype, @default_prototype)
    strategy = Keyword.get(opts, :strategy, @default_strategy)
    dispatch = Keyword.get(opts, :dispatch, false)
    verbose = Keyword.get(opts, :verbose, false)

    manifest = Manifest.load()
    cell = Manifest.fetch_cell!(manifest, prototype)
    trigger = build_trigger(incident, strategy)
    projections = build_projections(incident, strategy)

    Mix.shell().info("incident: #{incident}")
    Mix.shell().info("prototype: #{prototype}  role: #{cell.role}")
    Mix.shell().info("adapter: #{inspect(ColonyCore.LLM.adapter())}")

    if dispatch do
      run_dispatch(incident, prototype, trigger, verbose)
    else
      run_plan(trigger, projections, cell, verbose)
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

  defp run_dispatch(incident, prototype, trigger, verbose) do
    Mix.shell().info("mode: dispatch (live, requires kafka + api key)")
    Mix.shell().info("")

    case ColonyCell.start_cell(incident, prototype: prototype) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} ->
        Mix.shell().error("start_cell failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end

    {:ok, status} = ColonyCell.dispatch(incident, trigger)
    Mix.shell().info("dispatch: #{status}")
    Mix.shell().info("waiting 15s for reasoner...")
    Process.sleep(15_000)

    snap = ColonyCell.snapshot(incident)
    Mix.shell().info("")
    Mix.shell().info("snapshot:")
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

  defp build_trigger(incident, strategy) do
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

  defp build_projections(incident, strategy) do
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
        %{
          "type" => "incident.opened",
          "service" => "checkout-svc"
        }
      ]
    }
  end
end
