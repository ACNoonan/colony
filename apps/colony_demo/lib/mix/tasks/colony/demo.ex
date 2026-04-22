defmodule Mix.Tasks.Colony.Demo do
  @shortdoc "Run a reference self-healing infra scenario"

  @moduledoc """
  Run one of the shipped Phase 1 reference scenarios for `Colony`.

  Usage:

      mix colony.demo
      mix colony.demo --scenario canary_regression
      mix colony.demo --list

  Options:
    --scenario <name>   Scenario to run (default: `change_failure`)
    --list              Print the available scenarios and exit

  The current scenario set is the first proving ground for the self-healing
  infrastructure runtime:

  - `change_failure`   deploy/schema regression with downstream breakage
  - `canary_regression` canary rollout degrades live behavior
  """

  use Mix.Task

  @default_scenario "change_failure"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          scenario: :string,
          list: :boolean
        ]
      )

    if invalid != [] do
      Mix.shell().error("Unknown options: #{inspect(invalid)}")
      usage_error()
    end

    if Keyword.get(opts, :list, false) do
      print_scenarios()
    else
      scenario = Keyword.get(opts, :scenario, @default_scenario)
      Mix.Task.run("app.start")
      Mix.shell().info("scenario: #{scenario}")
      ColonyDemo.run(scenario)
    end
  end

  defp print_scenarios do
    Mix.shell().info("Available ColonyDemo scenarios:")

    Enum.each(ColonyDemo.available_scenarios(), fn scenario ->
      Mix.shell().info("  - #{scenario}")
    end)
  end

  defp usage_error do
    Mix.shell().error("Usage: mix colony.demo [--scenario <name>] [--list]")
    exit({:shutdown, 1})
  end
end
