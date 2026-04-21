%{
  cells: [
    %{
      name: "coordinator",
      kind: :agent,
      role: "coordinator",
      topic: "colony.agent.events",
      partition_scheme: {:field, :subject},
      prompt: "roles/coordinator.md",
      consumes: ["incident.opened", "impact.scan.reported", "mitigation.proposed", "mitigation.applied"],
      reasoning_triggers: ["mitigation.proposed"]
    },
    %{
      name: "specialist",
      kind: :agent,
      role: "specialist",
      topic: "colony.agent.events",
      partition_scheme: {:field, :subject},
      prompt: "roles/specialist.md",
      consumes: ["incident.triaged"],
      reasoning_triggers: ["incident.triaged"]
    },
    %{
      name: "detector.schema",
      kind: :agent,
      role: "detector",
      topic: "colony.agent.events",
      partition_scheme: {:field, :subject},
      prompt: "roles/detector.md",
      consumes: ["deployment.completed"]
    },
    %{
      name: "scanner",
      kind: :agent,
      role: "scanner",
      topic: "colony.agent.events",
      partition_scheme: {:field, :subject},
      prompt: "roles/scanner.md",
      consumes: ["impact.scan.requested"]
    },
    %{
      name: "applier",
      kind: :agent,
      role: "applier",
      topic: "colony.agent.events",
      partition_scheme: {:field, :subject},
      prompt: "roles/applier.md",
      consumes: ["mitigation.selected"]
    },
    %{
      name: "runtime.logger",
      kind: :system,
      role: "logger",
      topic: "colony.runtime.log",
      partition_scheme: :single,
      prompt: nil
    },
    %{
      name: "runtime.gate.auditor",
      kind: :system,
      role: "gate_auditor",
      topic: "colony.runtime.gate.rejected",
      partition_scheme: :single,
      prompt: nil
    }
  ]
}
