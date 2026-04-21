defmodule ColonyCore.Tools do
  @moduledoc """
  Per-role LLM tool schemas.

  Each tool maps 1:1 onto an event type a cell in that role is allowed to
  emit. The LLM picks a tool; the reasoner turns the tool call arguments
  into the `:data` map of a `ColonyCore.Event` and publishes it through
  `ColonyCell.emit/3`.

  This registry is the second place the swarm's emittable actions are
  named. The first is the role prompt in `swarm/roles/<role>.md`. They
  should stay in sync: if a role can emit an event, it's declared here,
  and its role prompt describes when to use it.
  """

  @type tool :: %{
          name: binary(),
          event_type: binary(),
          description: binary(),
          parameters: map()
        }

  @tools_by_role %{
    "specialist" => [
      %{
        name: "propose_mitigation",
        event_type: "mitigation.proposed",
        description:
          "Propose a mitigation strategy for this incident. Emit one `propose_mitigation` per viable strategy you can credibly execute. Never invent a strategy outside your specialty.",
        parameters: %{
          type: "object",
          properties: %{
            strategy: %{
              type: "string",
              description:
                "Strategy name, e.g. \"rollback\", \"schema_shim\", \"feature_flag_off\"."
            },
            estimated_recovery_seconds: %{
              type: "integer",
              description:
                "Honest estimate of seconds from mitigation.applied to incident.resolved. Do not round down for optimism."
            },
            target_version: %{
              type: "string",
              description:
                "For rollbacks, the service version to roll back to. Omit for non-rollback strategies."
            }
          },
          required: ["strategy", "estimated_recovery_seconds"]
        }
      }
    ],
    "coordinator" => [
      %{
        name: "select_mitigation",
        event_type: "mitigation.selected",
        description:
          "Record the mitigation strategy chosen for this incident. Pick one of the strategies that has been proposed; do not invent new strategies.",
        parameters: %{
          type: "object",
          properties: %{
            chosen: %{
              type: "string",
              description:
                "The strategy name, matching one of the `mitigation.proposed` events (e.g. \"rollback\", \"schema_shim\")."
            },
            reason: %{
              type: "string",
              description:
                "One short phrase explaining why this strategy beats the alternatives (e.g. \"fastest_recovery\", \"lowest_blast_radius\")."
            }
          },
          required: ["chosen", "reason"]
        }
      },
      %{
        name: "resolve_incident",
        event_type: "incident.resolved",
        description:
          "Mark the incident as resolved. Only emit this after a mitigation.applied event has been observed with result=ok.",
        parameters: %{
          type: "object",
          properties: %{
            outcome: %{
              type: "string",
              description: "\"mitigated\" if the fix held, \"recurred\" if a new failure appeared."
            },
            duration_seconds: %{
              type: "integer",
              description: "Approximate seconds from incident.opened to resolution."
            }
          },
          required: ["outcome"]
        }
      }
    ]
  }

  @spec for_role(binary()) :: [tool()]
  def for_role(role) when is_binary(role), do: Map.get(@tools_by_role, role, [])

  @spec roles() :: [binary()]
  def roles, do: Map.keys(@tools_by_role)

  @spec known?(binary(), binary()) :: boolean()
  def known?(role, event_type) do
    for_role(role) |> Enum.any?(&(&1.event_type == event_type))
  end

  @doc """
  Map a tool name (LLM-facing slug) back to the event type it produces.
  Returns `nil` if the tool isn't declared for the role.
  """
  @spec event_type_for(binary(), binary()) :: binary() | nil
  def event_type_for(role, tool_name) when is_binary(role) and is_binary(tool_name) do
    case Enum.find(for_role(role), &(&1.name == tool_name)) do
      nil -> nil
      %{event_type: et} -> et
    end
  end
end
