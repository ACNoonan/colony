defmodule ColonyDemo.Scenario do
  @moduledoc """
  Contract every **Phase 1** reference scenario implements.

  A scenario module owns its fixture events and the canned inputs the
  `mix colony.reason` task needs to exercise reasoning in isolation. Keeping
  scenario knowledge inside the module lets `ColonyDemo`, `mix colony.demo`,
  and `mix colony.reason` stay scenario-agnostic and makes adding a fourth
  scenario a single-file change.
  """

  alias ColonyCore.Event

  @type role :: binary()
  @type strategy :: binary()
  @type episode_subject :: binary()
  @type projections :: %{required(binary()) => [map()]}

  @doc "Short machine-friendly identifier, e.g. `\"change_failure\"`."
  @callback slug() :: binary()

  @doc "Operator-facing title, e.g. `\"Change-Failure Response\"`."
  @callback title() :: binary()

  @doc "One-line description shown in `mix colony.demo --list`."
  @callback description() :: binary()

  @doc "Default remediation episode subject used when no argument is passed."
  @callback default_episode_subject() :: episode_subject()

  @doc "Default `--strategy` value for the coordinator reasoning path."
  @callback default_strategy() :: strategy()

  @doc "Strategies the coordinator may legitimately select in this scenario."
  @callback candidate_remediations() :: [strategy()]

  @doc "Ordered synthetic events that drive the scripted `mix colony.demo` run."
  @callback events() :: [Event.t()]

  @doc """
  Canned trigger event for `mix colony.reason` in plan/dispatch mode.

  The role is the manifest role (`"coordinator"` or `"specialist"`); the
  episode subject is the `incident_id` (or equivalent) the operator is
  reasoning about; the strategy is the `--strategy` flag value.
  """
  @callback reason_trigger(role(), episode_subject(), strategy()) :: Event.t()

  @doc """
  Canned projections the cell presents to the reasoner in `mix colony.reason`
  plan mode. Shaped as `%{episode_subject => [projection_map, ...]}`.
  """
  @callback reason_projections(role(), episode_subject(), strategy()) :: projections()

  @optional_callbacks []
end
