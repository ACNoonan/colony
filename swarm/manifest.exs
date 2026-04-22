%{
  cells: [
    %{
      name: "coordinator",
      kind: :agent,
      role: "coordinator",
      topic: "colony.agent.events",
      partition_scheme: {:field, :subject},
      prompt: "roles/coordinator.md",
      consumes: [
        "episode.opened",
        "blast_radius.reported",
        "remediation.proposed",
        "remediation.applied",
        "remediation.verified"
      ],
      reasoning_triggers: ["remediation.proposed", "remediation.verified"]
    },
    %{
      name: "specialist",
      kind: :agent,
      role: "specialist",
      topic: "colony.agent.events",
      partition_scheme: {:field, :subject},
      prompt: "roles/specialist.md",
      consumes: ["blast_radius.assessed"],
      reasoning_triggers: ["blast_radius.assessed"]
    },
    %{
      name: "detector.schema",
      kind: :agent,
      role: "detector",
      topic: "colony.agent.events",
      partition_scheme: {:field, :subject},
      prompt: "roles/detector.md",
      consumes: ["change.detected"]
    },
    %{
      name: "scanner",
      kind: :agent,
      role: "scanner",
      topic: "colony.agent.events",
      partition_scheme: {:field, :subject},
      prompt: "roles/scanner.md",
      consumes: ["blast_radius.requested"]
    },
    %{
      name: "applier",
      kind: :agent,
      role: "applier",
      topic: "colony.agent.events",
      partition_scheme: {:field, :subject},
      prompt: "roles/applier.md",
      consumes: ["remediation.selected"]
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
