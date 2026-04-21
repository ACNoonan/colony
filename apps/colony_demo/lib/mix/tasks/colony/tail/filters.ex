defmodule Mix.Tasks.Colony.Tail.Filters do
  @moduledoc """
  Pure filter predicates for `mix colony.tail`.

  Kept as a separate module (not a Mix.Task private function) so the
  match logic is unit-testable without spinning up a Kafka consumer.
  """

  alias ColonyCore.Event

  @type filter_key :: :cell | :role | :correlation
  @type filters :: [{filter_key(), binary()}]

  @doc """
  Build a filter list from parsed OptionParser opts.

  Only keys we understand are kept; nil values drop out.
  """
  @spec build(keyword()) :: filters()
  def build(opts) do
    [
      cell: Keyword.get(opts, :cell),
      role: Keyword.get(opts, :role),
      correlation: Keyword.get(opts, :correlation)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  @doc """
  Human-readable filter summary for the tail status line.
  """
  @spec format(filters()) :: binary()
  def format([]), do: "none"

  def format(filters) do
    filters
    |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
    |> Enum.join(",")
  end

  @doc """
  Check whether `event` passes every filter in `filters`.

  An empty filter list passes everything. Each filter is a conjunction —
  all must match.
  """
  @spec passes?(Event.t(), filters()) :: boolean()
  def passes?(_event, []), do: true

  def passes?(%Event{} = event, filters) do
    Enum.all?(filters, fn
      {:cell, name} -> cell_match?(event, name)
      {:role, role} -> role_match?(event, role)
      {:correlation, id} -> event.correlation_id == id
    end)
  end

  @doc false
  def cell_match?(%Event{} = event, name) do
    candidates =
      [
        event.subject,
        event.partition_key,
        get_in(event.data, ["origin_subject"]),
        get_in(event.data, ["origin_partition_key"])
      ]
      |> Enum.reject(&is_nil/1)

    Enum.any?(candidates, &(&1 == name))
  end

  @doc false
  def role_match?(%Event{} = event, role) do
    candidates =
      [
        event.source,
        get_in(event.data, ["origin_source"])
      ]
      |> Enum.reject(&is_nil/1)

    Enum.any?(candidates, &source_role_matches?(&1, role))
  end

  defp source_role_matches?(source, role) when is_binary(source) and is_binary(role) do
    case String.split(source, ".", parts: 2) do
      [^role, _rest] -> true
      _ -> false
    end
  end

  defp source_role_matches?(_, _), do: false
end
