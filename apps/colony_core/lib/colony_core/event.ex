defmodule ColonyCore.Event do
  @moduledoc """
  Internal event envelope for command, observation, and replayable runtime state.

  This is CloudEvents-like rather than strict CloudEvents. The goal is to keep a
  stable shape while we validate the runtime semantics and topic layout.
  """

  @enforce_keys [:id, :type, :source, :subject, :data, :correlation_id, :causation_id]
  defstruct [
    :id,
    :type,
    :source,
    :subject,
    :data,
    :correlation_id,
    :causation_id,
    :tenant_id,
    :swarm_id,
    :agent_id,
    :action_key,
    :partition_key,
    :sequence,
    :schema_version,
    :recorded_at,
    :traceparent
  ]

  @required ~w(id type source subject data correlation_id causation_id)a

  @type t :: %__MODULE__{
          id: binary(),
          type: binary(),
          source: binary(),
          subject: binary(),
          data: map(),
          correlation_id: binary(),
          causation_id: binary(),
          tenant_id: binary() | nil,
          swarm_id: binary() | nil,
          agent_id: binary() | nil,
          action_key: binary() | nil,
          partition_key: binary() | nil,
          sequence: non_neg_integer() | nil,
          schema_version: pos_integer() | nil,
          recorded_at: DateTime.t() | nil,
          traceparent: binary() | nil
        }

  def new(attrs) when is_list(attrs) do
    attrs |> Enum.into(%{}) |> new()
  end

  def new(attrs) when is_map(attrs) do
    attrs
    |> Map.put_new(:recorded_at, DateTime.utc_now())
    |> Map.put_new(:schema_version, 1)
    |> then(&struct!(__MODULE__, &1))
    |> validate!()
  end

  def validate!(%__MODULE__{} = event) do
    Enum.each(@required, fn field ->
      if blank?(Map.fetch!(event, field)) do
        raise ArgumentError, "event field #{inspect(field)} must be present"
      end
    end)

    event
  end

  def type_family(%__MODULE__{type: type}) when is_binary(type) do
    type
    |> String.split(".", parts: 2)
    |> List.first()
  end

  def idempotency_key(%__MODULE__{} = event) do
    Enum.join([event.tenant_id, event.swarm_id, event.agent_id, event.id], ":")
  end

  def encode(%__MODULE__{} = event) do
    event
    |> Map.from_struct()
    |> Map.update(:recorded_at, nil, &to_string/1)
    |> Jason.encode()
  end

  def encode!(%__MODULE__{} = event) do
    {:ok, json} = encode(event)
    json
  end

  def decode(json) when is_binary(json) do
    with {:ok, map} <- Jason.decode(json) do
      attrs =
        map
        |> Map.new(fn {k, v} -> {String.to_existing_atom(k), v} end)
        |> Map.update(:recorded_at, nil, fn
          nil -> nil
          str -> DateTime.from_iso8601(str) |> elem(1)
        end)

      {:ok, struct!(__MODULE__, attrs)}
    end
  end

  defp blank?(value) when value in [nil, ""], do: true
  defp blank?(value) when is_map(value), do: map_size(value) == 0
  defp blank?(value) when is_list(value), do: value == []
  defp blank?(_value), do: false
end
