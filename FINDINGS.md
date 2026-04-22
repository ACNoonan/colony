# Findings

This file is the **production-readiness and hardening roadmap** for the
self-healing infrastructure runtime described in `README.md`. The reference
change-failure scenario (capability ladder step 1) proves coordination,
replay, and operator visibility; the entries below are the gaps between
that proving ground and **trustworthy bounded autonomy** (gates, async
publish paths, budgets, observability guarantees).

Each entry follows: what the risk is, why we're unsure, how to test. Phase
numbers are historical ordering from bring-up; they align with README
near-term priorities (harden primitives before widening scenarios).

## Cold-broker boot drag (Phase 2, partially addressed)

`ColonyCell.SystemSupervisor` starts `Systems.Logger` and
`Systems.GateAuditor` on app boot, both of which call
`ColonyKafka.subscribe/2`. For the test environment, `config.exs`'s
test-env block swaps in `ColonyKafka.Adapters.Unconfigured`, and
`mix colony.reason` (plan mode) sets `COLONY_DISABLE_KAFKA=1` for the
same effect. Full-stack boot against a cold broker in dev or prod
isn't covered — brod's `:brod.start_link_group_subscriber_v2/1` may
still block before returning `{:error, _}`.

- **How to test:** `docker compose down && time iex -S mix` in dev env.
  If > ~3s is spent in SystemSupervisor init, lazy-start the
  subscriptions behind a retry loop instead of blocking in cell `init`.

## `mix colony.manifest` output formatting

`Mix.Tasks.Colony.Manifest` computes column widths and pads by hand.
Not visually verified.

- **How to test:** `mix colony.manifest` on the shipped
  `swarm/manifest.exs`. Columns should line up; prompt column should be
  12 hex chars or `-`.

## `Event.decode/1` + forward compatibility

Decoder uses `String.to_existing_atom/1`. An event serialized on a newer
node with an unknown field raises `ArgumentError` instead of ignoring the
field. Decide loud-fail vs. silent-drop before we have mixed versions in
production.

- **How to test:** hand-edit a JSON event to include `"future_field":"x"`
  and attempt `Event.decode/1`.

## System logger drops events while down

`ColonyCell.Systems.Logger` subscribes with a fresh `group_id` each time
it starts and uses `begin_offset: :latest`. Events produced during a
restart window do not appear in `colony.runtime.log`. Observability only,
not correctness — but operators should know.

- **How to test:** kill the logger pid, produce events, restart,
  confirm the dropped events are absent from `colony.runtime.log`.

## GateAuditor + Logger aren't unit-tested directly (Phase 3)

Both system cells start a subscription via `ColonyKafka.subscribe/2` in
`init`. Without a test-env adapter override, starting either GenServer in
an ExUnit test triggers a real Brod subscribe. No dedicated unit tests
for their cast/snapshot paths were added for this reason.

- **How to test:** add a `skip_subscribe: true` opt so tests can drive
  state via `GenServer.cast/2` without a broker. Assert counter +
  recent-buffer behavior directly.

## Manifest loaded on every publish (Phase 3)

`ColonyCore.Envelope.Gate` calls `Manifest.load()` (a `File.read!` +
`Code.eval_file`) when no manifest is passed in. `ColonyKafka.publish/3`
hits this on every outbound event. Fine for the demo; bad for a busy
topic.

- **How to test:** benchmark publish throughput. If this shows up,
  memoize via `:persistent_term` at app boot — `ColonyCell.SystemSupervisor`
  already has to load the manifest, so it's the natural owner.

## Gate mode default is `:warn`, not `:enforce` (Phase 3)

Every violation currently logs + emits `runtime.gate.rejected` and then
publishes the offending event anyway. This is deliberate for bring-up
(see Phase 3 plan). It's a risk only in the sense that nobody is forced
to look at the warnings.

- **How to test:** watch `colony.runtime.gate.rejected` for real drift
  during a demo run. If nothing shows up after a week of runs, flip to
  `:enforce` in config. If things show up, fix them first.

## `mix colony.tail` role filter + filter tests (closed 2026-04-22)

Filters extracted into `Mix.Tasks.Colony.Tail.Filters` with unit tests
over the match matrix (subject/partition_key/origin_subject for cell,
source prefix/origin_source prefix for role, correlation exact match,
composite conjunction). Role matching keys off the `<role>.<partition>`
source convention — now grounded in `manifest_cell.role` via
`ColonyCell.Cell.default_source`, so the filter works for both
scripted and reasoner-emitted events.

## `ColonyCell.emit/3` blocks the cell on Kafka (Phase 5)

`emit/3` is a `GenServer.call` that publishes inline, so a slow broker
holds the cell call queue. Fine for demo; wrong for production-scale
agent reasoning.

- **How to test:** benchmark emit latency against a slow broker (e.g.
  tc-netem). If latencies spike cell throughput, switch emit to `cast`
  with a separate async publisher process or a small buffering pool.

## No rate/budget gate on Reasoner (Phase 6)

Nothing prevents a misbehaving cell from producing an event whose type
re-triggers the same cell's reasoner, in a loop. Coordinator's
`remediation.proposed` trigger currently can't self-loop (coordinator
doesn't emit proposed), but the safety isn't structural.

- **How to test:** add a role whose tool set includes the event type
  that triggers its own reasoning, run one reasoning round, confirm
  runaway. Fix is a per-cell token budget (tokens used / max per
  correlation) and/or a depth counter carried on event data.

## LLM adapters validated against live APIs (closed 2026-04-21)

Anthropic adapter: one live call, `stop_reason=tool_use`, parser produced
a clean `mitigation.selected` emit with `chosen=rollback,
reason=fastest_recovery`. OpenAI adapter: same result, same shape.
Tool name rename (dotted → slug, `select_mitigation` in the Tools
registry) was needed for both providers since neither allows `.` in
tool names; the Reasoner maps slug back to dotted event type at emit
time via `ColonyCore.Tools.event_type_for/2`.

## Multi-role specialist → coordinator chain validated (closed 2026-04-21)

Full `--dispatch` loop through Kafka: specialist emitted two
`mitigation.proposed` from one LLM call with distinct action_keys;
coordinator reasoned twice but the second emit was deduped via
`applied_actions` check; applier received exactly one
`mitigation.selected` event. Zero drift warnings across all cells.
Snapshot printed for all three cells.

## `ColonyDemo.run()` multi-role end-to-end (closed 2026-04-22)

`make up && mix run -e "ColonyDemo.run()"` exercised end-to-end with the
canonical control-loop vocabulary after the ADR-0001 migration.
`inspect_cells` produced `coordinator:incident-042`,
`detector:checkout-svc`, `scanner:incident-042`,
`specialist:incident-042`, and `applier:incident-042`. Crash-and-replay
of `detector:checkout-svc` converged to identical projections.
Action-level dedup fired as expected on the retry. All published event
types were canonical (`change.detected`, `episode.opened`,
`blast_radius.requested/reported/assessed`, `remediation.proposed/
selected/applied/verified`, `episode.closed`).

## Commit `1a85585` missing co-author trailer

Phase 1 commit omits the `Co-Authored-By: Claude Opus 4.7` trailer that
every other commit in the history carries. Cosmetic. No planned fix unless
history gets rewritten for another reason.
