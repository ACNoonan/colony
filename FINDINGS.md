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

## Commit `1a85585` missing co-author trailer

Phase 1 commit omits the `Co-Authored-By: Claude Opus 4.7` trailer that
every other commit in the history carries. Cosmetic. No planned fix unless
history gets rewritten for another reason.
