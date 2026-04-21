defmodule ColonyCore.Envelope.Gate do
  @moduledoc """
  Pre-publish validation for events crossing the Kafka boundary.

  `ColonyCore.Event.new/1` is the cheap shape check (required fields,
  defaults). The gate is the semantic check that knows the manifest. Rules
  enforced today:

    * `:bad_schema_version` — event's `schema_version` must be in the
      known set.
    * `:bad_prompt_hash` — if present, must be a lowercase 64-char SHA-256
      hex digest.
    * `:partition_mismatch` — if `partition_key` is set AND the manifest
      describes the target topic, the key must match what the topic's
      partition scheme would produce for this event.

  A rule that cannot be checked (e.g. topic is not in the manifest, or
  manifest load fails) passes silently rather than blocking traffic.

  `check/3` is pure and side-effect-free; the caller decides what to do
  with a violation (warn + publish, block + log, etc.).
  """

  alias ColonyCore.Event
  alias ColonyCore.Manifest

  @known_schema_versions [1]

  @type violation :: {atom(), map()}

  @spec check(Event.t(), binary(), Manifest.t() | nil) :: :ok | {:error, violation()}
  def check(%Event{} = event, topic, manifest \\ nil) when is_binary(topic) do
    with :ok <- check_schema_version(event),
         :ok <- check_prompt_hash(event),
         :ok <- check_partition(event, topic, manifest || safe_load_manifest()) do
      :ok
    end
  end

  defp check_schema_version(%Event{schema_version: v}) when v in @known_schema_versions, do: :ok

  defp check_schema_version(%Event{schema_version: v}) do
    {:error, {:bad_schema_version, %{got: v, expected: @known_schema_versions}}}
  end

  defp check_prompt_hash(%Event{prompt_hash: nil}), do: :ok

  defp check_prompt_hash(%Event{prompt_hash: h}) when is_binary(h) do
    if h =~ ~r/^[0-9a-f]{64}$/ do
      :ok
    else
      {:error, {:bad_prompt_hash, %{got: h}}}
    end
  end

  defp check_prompt_hash(%Event{prompt_hash: other}) do
    {:error, {:bad_prompt_hash, %{got: inspect(other)}}}
  end

  defp check_partition(_event, _topic, nil), do: :ok

  defp check_partition(%Event{partition_key: nil}, _topic, _manifest), do: :ok

  defp check_partition(%Event{partition_key: key} = event, topic, manifest) do
    case safe_cell_id_for(manifest, topic, event) do
      {:ok, expected} when expected == key ->
        :ok

      {:ok, expected} ->
        {:error, {:partition_mismatch, %{topic: topic, expected: expected, got: key}}}

      :skip ->
        :ok
    end
  end

  defp safe_cell_id_for(manifest, topic, event) do
    {:ok, Manifest.cell_id_for!(manifest, topic, event)}
  rescue
    ArgumentError -> :skip
  end

  defp safe_load_manifest do
    Manifest.load()
  rescue
    _ -> nil
  end
end
