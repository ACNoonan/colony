defmodule Mix.Tasks.Colony.Manifest do
  @moduledoc """
  Print the colony swarm manifest.

      mix colony.manifest

  One line per cell: name, kind, role, topic, partition scheme, prompt
  hash. This is the one-screen view of the whole swarm — the answer to
  "what does this runtime actually do?"
  """

  @shortdoc "Print the colony swarm manifest"

  use Mix.Task

  alias ColonyCore.Manifest
  alias ColonyCore.Prompt

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    manifest = Manifest.load()

    rows = Enum.map(manifest.cells, &row/1)

    widths = %{
      name: max(width(rows, :name), String.length("NAME")),
      kind: max(width(rows, :kind), String.length("KIND")),
      role: max(width(rows, :role), String.length("ROLE")),
      topic: max(width(rows, :topic), String.length("TOPIC")),
      scheme: max(width(rows, :scheme), String.length("PARTITION"))
    }

    Mix.shell().info("swarm: #{length(manifest.cells)} cells")
    Mix.shell().info("")
    Mix.shell().info(header(widths))
    Mix.shell().info(rule(widths))

    Enum.each(rows, fn row -> Mix.shell().info(format(row, widths)) end)
  end

  defp row(cell) do
    %{
      name: cell.name,
      kind: Atom.to_string(cell.kind),
      role: cell.role,
      topic: cell.topic,
      scheme: format_scheme(cell.partition_scheme),
      prompt: prompt_hash(cell)
    }
  end

  defp format_scheme(:single), do: "single"
  defp format_scheme({:field, f}), do: "field:#{f}"
  defp format_scheme({:hash, f}), do: "hash:#{f}"

  defp prompt_hash(%{kind: :system}), do: "-"

  defp prompt_hash(cell) do
    cell |> Prompt.hash_for() |> String.slice(0, 12)
  end

  defp width(rows, key) do
    rows
    |> Enum.map(&String.length(Map.fetch!(&1, key)))
    |> Enum.max()
  end

  defp header(w) do
    [
      pad("NAME", w.name),
      pad("KIND", w.kind),
      pad("ROLE", w.role),
      pad("TOPIC", w.topic),
      pad("PARTITION", w.scheme),
      "PROMPT"
    ]
    |> Enum.join("  ")
  end

  defp rule(w) do
    [
      String.duplicate("-", w.name),
      String.duplicate("-", w.kind),
      String.duplicate("-", w.role),
      String.duplicate("-", w.topic),
      String.duplicate("-", w.scheme),
      String.duplicate("-", 12)
    ]
    |> Enum.join("  ")
  end

  defp format(row, w) do
    [
      pad(row.name, w.name),
      pad(row.kind, w.kind),
      pad(row.role, w.role),
      pad(row.topic, w.topic),
      pad(row.scheme, w.scheme),
      row.prompt
    ]
    |> Enum.join("  ")
  end

  defp pad(s, width) do
    s <> String.duplicate(" ", max(0, width - String.length(s)))
  end
end
