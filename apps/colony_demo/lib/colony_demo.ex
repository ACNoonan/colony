defmodule ColonyDemo do
  @moduledoc """
  Reference scenarios for **Phase 1: incident coordination** (capability
  ladder step 1).

  `Colony` targets self-healing infrastructure; these demos are the first hard
  proving ground, not the whole product. They exercise the same runtime
  primitives used for broader remediation: manifest routing, partitioned cells,
  fan-out/fan-in, reasoning triggers, bounded actions, crash/replay, and
  idempotency.

  Shipped reference scenarios today:

  - `:change_failure` — deploy/schema regression with downstream breakage
  - `:canary_regression` — canary rollout degrades customer-facing behavior
  - `:bad_config_rollout` — bad dynamic-config push lands, mitigations revert

  All three scenarios walk the same five-phase control loop:

    1. Ingest      — change signal arrives
    2. Fan-out     — one remediation episode opens, N scans are requested
    3. Fan-in      — scans report back, coordinator triages
    4. Decide+act  — specialists propose, coordinator selects, applier executes
    5. Close       — the episode is resolved

  Detection events partition by service; incident events partition by
  `incident_id` so one episode's causal chain lands on one cell.

  Event fixtures live under `ColonyDemo.Scenarios.*`.
  """

  require Logger

  alias ColonyCore.Event
  alias ColonyCore.Manifest
  alias ColonyCell

  @event_topic Application.compile_env(:colony_demo, :event_topic, "colony.agent.events")

  @scenarios [
    ColonyDemo.Scenarios.ChangeFailure,
    ColonyDemo.Scenarios.CanaryRegression,
    ColonyDemo.Scenarios.BadConfigRollout
  ]

  def run, do: run(default_scenario())

  def run(scenario_name) do
    scenario = scenario_module!(scenario_name)

    Logger.info("=== Colony Demo: #{scenario.title()} (ladder step 1) ===")

    ensure_topic()
    start_consumer()
    # Give the consumer time to join the group and get assignments
    Process.sleep(5_000)

    events = sample_events(scenario_name)
    produce(events)
    # Give the consumer time to process
    Process.sleep(5_000)

    inspect_cells()
    simulate_crash_and_replay(events)
    demonstrate_action_dedup(events)

    Logger.info("=== Demo Complete ===")
  end

  def ensure_topic do
    brokers = Application.fetch_env!(:colony_kafka, :brokers)

    case :brod.create_topics(
           brokers,
           [
             %{
               name: @event_topic,
               num_partitions: 3,
               replication_factor: 1,
               assignments: [],
               configs: []
             }
           ],
           %{timeout: 5_000}
         ) do
      :ok ->
        Logger.info("Created topic #{@event_topic}")

      {:error, :topic_already_exists} ->
        Logger.info("Topic #{@event_topic} already exists")

      {:error, reason} ->
        Logger.warning("Topic creation: #{inspect(reason)}")
    end
  end

  def start_consumer do
    manifest = Manifest.load()

    handler = fn event ->
      partition = Manifest.cell_id_for!(manifest, @event_topic, event)
      consumers = Manifest.consuming_cells(manifest, @event_topic, event.type)

      if consumers == [] do
        Logger.debug("[consumer] no cells consume #{event.type}; #{event.id} ignored")
      end

      Enum.each(consumers, fn manifest_cell ->
        case ColonyCell.start_for(manifest_cell, partition) do
          {:ok, runtime_id} ->
            Logger.info("[consumer] #{event.id} (#{event.type}) → #{runtime_id}")
            ColonyCell.dispatch(runtime_id, event)

          {:error, reason} ->
            Logger.warning(
              "[consumer] start_for #{manifest_cell.name} failed: #{inspect(reason)}"
            )
        end
      end)

      :ok
    end

    # Unique group ID per run so the demo always starts from latest offset
    group_id = "colony-demo-#{System.unique_integer([:positive])}"

    {:ok, _pid} =
      ColonyKafka.subscribe(@event_topic, group_id: group_id, handler: handler)

    Logger.info("Consumer subscribed to #{@event_topic} (group: #{group_id})")
  end

  def produce(events) do
    Enum.each(events, fn event ->
      :ok = ColonyKafka.publish(@event_topic, event)
      Logger.info("[producer] Published #{event.id} (#{event.type})")
    end)
  end

  def inspect_cells do
    Logger.info("=== Cell Snapshots ===")

    for {cell_id, _pid, _} <-
          Registry.select(ColonyCell.Registry, [
            {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}
          ]),
        is_binary(cell_id) do
      snapshot = ColonyCell.snapshot(cell_id)

      Logger.info(
        "Cell #{cell_id}: #{snapshot.handled_events} events, " <>
          "actions=#{snapshot.applied_actions}, " <>
          "last_seq=#{snapshot.last_sequence}, projections=#{inspect(snapshot.projections)}"
      )
    end
  end

  def simulate_crash_and_replay(events) do
    Logger.info("=== Simulating Cell Crash ===")

    manifest = Manifest.load()

    agent_entries =
      ColonyCell.Registry
      |> Registry.select([{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.filter(fn {cell_id, _pid} -> is_binary(cell_id) end)

    case agent_entries do
      [{cell_id, pid} | _] ->
        before = ColonyCell.snapshot(cell_id)

        Logger.info(
          "Cell #{cell_id} BEFORE crash: #{before.handled_events} events, " <>
            "actions=#{before.applied_actions}, last_seq=#{before.last_sequence}"
        )

        Logger.info("Killing cell #{cell_id} (pid: #{inspect(pid)})")
        Process.exit(pid, :kill)
        Process.sleep(200)

        # The DynamicSupervisor may have already restarted it (temporary restart),
        # or we need to start a fresh one. Either way, get a clean cell.
        case ColonyCell.start_cell(cell_id) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
        end

        fresh = ColonyCell.snapshot(cell_id)
        Logger.info("Cell #{cell_id} after crash (fresh state): #{fresh.handled_events} events")

        # Replay the same events — idempotent cells should accept them all as new
        partition =
          case String.split(cell_id, ":", parts: 2) do
            [_role, p] -> p
            [single] -> single
          end

        cell_events =
          Enum.filter(events, fn e ->
            Manifest.cell_id_for!(manifest, @event_topic, e) == partition
          end)

        Logger.info("Replaying #{length(cell_events)} events...")

        Enum.each(cell_events, fn event ->
          {:ok, status} = ColonyCell.dispatch(cell_id, event)
          Logger.info("[replay] #{event.id} (#{event.type}) → #{status}")
        end)

        after_replay = ColonyCell.snapshot(cell_id)

        Logger.info(
          "Cell #{cell_id} AFTER replay: #{after_replay.handled_events} events, " <>
            "actions=#{after_replay.applied_actions}, last_seq=#{after_replay.last_sequence}"
        )

        Logger.info("Projections: #{inspect(after_replay.projections)}")

      [] ->
        Logger.warning("No cells to crash")
    end
  end

  def demonstrate_action_dedup(events) do
    Logger.info("=== Action-Level Idempotency ===")

    manifest = Manifest.load()
    applied = Enum.find(events, fn e -> e.type == "remediation.applied" end)
    partition = Manifest.cell_id_for!(manifest, @event_topic, applied)
    [coordinator | _] = Manifest.consuming_cells(manifest, @event_topic, applied.type)
    {:ok, cell_id} = ColonyCell.start_for(coordinator, partition)

    retry_event =
      Event.new(%{
        id: "evt-applied-retry-#{System.unique_integer([:positive])}",
        type: applied.type,
        source: applied.source,
        subject: applied.subject,
        partition_key: applied.partition_key,
        tenant_id: applied.tenant_id,
        swarm_id: applied.swarm_id,
        agent_id: applied.agent_id,
        action_key: applied.action_key,
        correlation_id: applied.correlation_id,
        causation_id: applied.id,
        sequence: 99,
        data: applied.data
      })

    Logger.info(
      "Dispatching retry #{retry_event.id} " <>
        "(action_key=#{retry_event.action_key}) → cell:#{cell_id}"
    )

    {:ok, status} = ColonyCell.dispatch(cell_id, retry_event)
    Logger.info("[retry] #{retry_event.id} → #{status} (expected :duplicate_action)")

    snapshot = ColonyCell.snapshot(cell_id)

    Logger.info(
      "Cell #{cell_id} after retry: #{snapshot.handled_events} events, " <>
        "actions=#{snapshot.applied_actions}, last_seq=#{snapshot.last_sequence}"
    )
  end

  def sample_events, do: sample_events(default_scenario())

  def sample_events(scenario_name) do
    scenario_module!(scenario_name).events()
  end

  @doc """
  All registered scenario modules, in listing order.
  """
  @spec scenarios() :: [module()]
  def scenarios, do: @scenarios

  @doc """
  Slugs of all registered scenarios, preserving listing order.
  """
  @spec available_scenarios() :: [binary()]
  def available_scenarios, do: Enum.map(@scenarios, & &1.slug())

  @doc """
  Default scenario slug for tasks that don't accept `--scenario`.
  """
  @spec default_scenario() :: binary()
  def default_scenario, do: hd(@scenarios).slug()

  @doc """
  Resolve a slug (string or atom) to its scenario module.

  Raises `ArgumentError` on an unknown slug.
  """
  @spec scenario_module!(binary() | atom()) :: module()
  def scenario_module!(slug) when is_atom(slug), do: scenario_module!(Atom.to_string(slug))

  def scenario_module!(slug) when is_binary(slug) do
    case Enum.find(@scenarios, &(&1.slug() == slug)) do
      nil ->
        raise ArgumentError,
              "unknown ColonyDemo scenario #{inspect(slug)}; expected one of " <>
                inspect(available_scenarios())

      module ->
        module
    end
  end
end
