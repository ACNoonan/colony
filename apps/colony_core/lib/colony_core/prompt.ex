defmodule ColonyCore.Prompt do
  @moduledoc """
  Layered prompt loader for agent cells.

  Every agent cell's effective system prompt is the concatenation of
  `constitution.md` and its role fragment, in that order. The concatenated
  text is hashed with SHA-256; the hex digest is stamped on every event the
  cell emits as `prompt_hash`, so operators reading the event log can
  reconstruct exactly which instructions were in force.

  System cells return `""` / `nil` because they never read prompts.
  """

  alias ColonyCore.Manifest

  @constitution_file "constitution.md"
  @separator "\n\n---\n\n"

  @spec text_for(Manifest.Cell.t()) :: binary()
  def text_for(%Manifest.Cell{kind: :system}), do: ""

  def text_for(%Manifest.Cell{kind: :agent, prompt: prompt}) when is_binary(prompt) do
    constitution = read!(@constitution_file)
    role = read!(prompt)
    constitution <> @separator <> role
  end

  @spec hash_for(Manifest.Cell.t()) :: binary() | nil
  def hash_for(%Manifest.Cell{kind: :system}), do: nil

  def hash_for(%Manifest.Cell{} = cell) do
    cell
    |> text_for()
    |> hash()
  end

  @spec hash(binary()) :: binary()
  def hash(text) when is_binary(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
  end

  defp read!(rel) do
    Manifest.swarm_dir()
    |> Path.join(rel)
    |> File.read!()
  end
end
