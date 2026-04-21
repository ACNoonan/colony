# Findings

Running log of assumptions and risks in the colony runtime that haven't
been verified end-to-end. Each entry: what the risk is, why we're unsure,
how to test.

## Cold-broker boot drag (Phase 2)

`ColonyCell.SystemSupervisor` starts `ColonyCell.Systems.Logger` on app
boot, which calls `ColonyKafka.subscribe/2`. Against an unreachable broker,
Brod's `:brod.start_link_group_subscriber_v2/1` may block before returning
`{:error, _}`, slowing umbrella startup.

- **How to test:** `docker compose down && time mix test` (or any app boot).
  If > ~3s spent in SystemSupervisor init, override adapter in test env:
  `config :colony_kafka, adapter: ColonyKafka.Adapters.Unconfigured` in a
  new `config/test.exs`.

## First-time compile + test run (Phase 1 + 2)

No commit in this branch has been compiled or tested locally — the machine
lacks an Elixir toolchain. Everything was authored blind. CI is the first
real exercise.

- **How to test:** `mix deps.get && mix compile && mix test` on a host with
  Elixir 1.17+. Expect to find at least a typo or a missing include.

## `mix colony.manifest` output formatting

`Mix.Tasks.Colony.Manifest` computes column widths and pads by hand. Not
visually verified.

- **How to test:** `mix colony.manifest` on the shipped `swarm/manifest.exs`.
  Columns should line up; prompt column should be 12 hex chars or `-`.

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

- **How to test:** either (a) add `ColonyKafka.Adapters.Memory` that queues
  published events and no-ops subscribe, and switch to it in `config/test.exs`;
  or (b) add a `skip_subscribe: true` opt so tests can drive state via
  `GenServer.cast/2` without a broker. Then assert counter + recent-buffer
  behavior directly.

## Manifest loaded on every publish (Phase 3)

`ColonyCore.Envelope.Gate` calls `Manifest.load()` (a `File.read!` +
`Code.eval_file`) when no manifest is passed in. `ColonyKafka.publish/2`
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

## `mix colony.tail` has no `--role` filter (Phase 4)

Resolving `event.source` (e.g. `"specialist.rollback"`) to a manifest
`role` requires a source→role map that doesn't exist yet. The cell filter
covers the common case (one cell, one incident) but not "show me every
event any specialist ever emitted."

- **How to test:** demo run, `mix colony.tail --role specialist` — today
  this errors on unknown option. Fix is either a naming convention
  (`<role>.<instance>`) enforced in the constitution, or a `source_prefix`
  field on manifest cells.

## `mix colony.tail` filter logic is untested (Phase 4)

`passes?/2` and `cell_match?/2` are private and tested only by running the
task against real Kafka. If we regress filter behavior, only a human
spot-check will catch it.

- **How to test:** extract filters into `Mix.Tasks.Colony.Tail.Filters`
  (or similar) and add unit tests around the match matrix (subject,
  partition_key, origin_subject from runtime.log envelopes).

## Jido backend not yet wired (Phase 5)

Phase 5 landed the plumbing — cells can carry a prototype + prompt_hash,
`ColonyCell.emit/3` auto-stamps outbound events, dispatch detects prompt
drift — but no agent cell yet runs an LLM. When a Jido (or other agent
framework) integration lands, it slots into `init` where we load the
prototype and into `emit` where we already stamp provenance.

- **How to test:** add Jido as a dep, wire a minimal reasoning loop that
  calls `ColonyCell.emit/3`, verify the event's `prompt_hash` matches the
  snapshot's `prompt_hash` and that the gate accepts it.

## Demo does not yet use prototype-aware cells (Phase 5)

`ColonyDemo.start_consumer` still calls `ColonyCell.start_cell(cell_id)`
without `:prototype`. Cells therefore don't load prompts and emitted
events (none today) wouldn't be stamped. The plumbing works — nothing
opts in yet.

- **How to test:** design an event-type → prototype mapping (e.g.
  `incident.*` → coordinator, `impact.scan.*` → scanner) and pass
  `prototype: <name>` to `ColonyCell.start_cell/2` when the demo consumer
  first spins a cell up. Then a replay of historical events after a
  constitution change should surface non-zero `drift_events` in the
  snapshot.

## `ColonyCell.emit/3` blocks the cell on Kafka (Phase 5)

`emit/3` is a `GenServer.call` that publishes inline, so a slow broker
holds the cell call queue. Fine for demo; wrong for production-scale
agent reasoning.

- **How to test:** benchmark emit latency against a slow broker (e.g.
  tc-netem). If latencies spike cell throughput, switch emit to `cast`
  with a separate async publisher process or a small buffering pool.

## `.env` isn't auto-loaded (Phase 6)

`config/runtime.exs` reads `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` /
`COLONY_LLM_ADAPTER` from `System.get_env`. `.env` is gitignored but
nothing in the repo sources it. Operator must `set -a; source .env; set +a`
before `mix` or `iex -S mix` sees the keys.

- **How to test:** run `mix run -e "IO.inspect(Application.get_env(:colony_core, :llm_anthropic))"`
  after a fresh terminal without sourcing — expect `api_key: nil`. Fix is
  either a one-line shell wrapper in Makefile (`include .env; export`)
  or a `dotenvy` dep.

## Reasoner-emitted events have no sequence (Phase 6)

`ColonyCell.Reasoner.emit_tool_call/3` builds attrs without `:sequence`,
so the outbound event's `sequence` field is nil. Projection ordering
today falls back to `recorded_at`, but any operator tool that relies on
`sequence` for ordering (timeline already does) will see gaps for
LLM-emitted events.

- **How to test:** `mix colony.timeline <incident>` after a reasoning run;
  entries sourced from the reasoner will show `seq=` blank. Fix is to
  read `last_sequence` from cell state before emit (extra `GenServer.call`
  per emit) or have `ColonyCell.emit/3` auto-increment sequence when not
  provided.

## No rate/budget gate on Reasoner (Phase 6)

Nothing prevents a misbehaving cell from producing an event whose type
re-triggers the same cell's reasoner, in a loop. Coordinator's
`mitigation.proposed` trigger currently can't self-loop (coordinator
doesn't emit proposed), but the safety isn't structural.

- **How to test:** add a role whose tool set includes the event type
  that triggers its own reasoning, run one reasoning round, confirm
  runaway. Fix is a per-cell token budget (tokens used / max per
  correlation) and/or a depth counter carried on event data.

## LLM adapter tool-use parsers are untested against live APIs (Phase 6)

Anthropic and OpenAI adapters translate messages/tools to each provider's
wire shape, and parse the response back to a normalized map. None of
this has hit a real API. Likely correct (shapes follow current docs) but
the first real call may surface something off.

- **How to test:** source `.env`, `iex -S mix`, call
  `ColonyCore.LLM.call([%{role: :user, content: "say hi"}], tools: [])`
  against each provider. Fix in the adapter's `parse/1`.

## LLM adapters validated against live APIs (closed 2026-04-21)

Anthropic adapter: one live call, `stop_reason=tool_use`, parser produced
a clean `mitigation.selected` emit with `chosen=rollback,
reason=fastest_recovery`. OpenAI adapter: same result, same shape.
Tool name rename (dotted → slug, `select_mitigation` in the Tools
registry) was needed for both providers since neither allows `.` in
tool names; the Reasoner maps slug back to dotted event type at emit
time via `ColonyCore.Tools.event_type_for/2`.

## Plan-mode still emits two subscribe-failed warnings (Phase 7)

With `COLONY_DISABLE_KAFKA=1`, system cells still start and try to
subscribe; the Unconfigured adapter returns `:kafka_adapter_not_configured`
and they log a warning. Not broken, just noisy.

- **How to test:** `mix colony.reason` — count warnings. Fix is either
  (a) don't start SystemSupervisor when kafka is disabled, or (b) lower
  the "subscribe failed" log level to debug when the reason is
  `:kafka_adapter_not_configured` specifically.

## Commit `1a85585` missing co-author trailer

Phase 1 commit omits the `Co-Authored-By: Claude Opus 4.7` trailer that
every other commit in the history carries. Cosmetic. No planned fix unless
history gets rewritten for another reason.
