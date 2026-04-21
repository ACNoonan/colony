defmodule ColonyCore.Manifest do
  @moduledoc """
  Declarative swarm topology.

  The manifest is the single source of truth for which cells exist, what
  role they play, which topic they work against, and how events partition
  onto them. Anything that spawns a cell outside this file is a bug.

  The on-disk format is a plain Elixir map evaluated from
  `swarm/manifest.exs`:

      %{
        cells: [
          %{
            name: "coordinator",
            kind: :agent,
            role: "coordinator",
            topic: "colony.agent.events",
            partition_scheme: {:field, :subject},
            prompt: "roles/coordinator.md"
          },
          ...
        ]
      }

  Partition schemes:

    * `:single`          — one partition, one cell
    * `{:field, atom}`   — partition by the named envelope field (e.g.
                            `:subject`, `:partition_key`, `:tenant_id`)
    * `{:hash, atom}`    — hash the named envelope field

  Agent cells MUST declare a `prompt` path relative to the swarm dir.
  System cells MUST set `prompt: nil`.
  """

  defmodule Cell do
    @moduledoc false

    @enforce_keys [:name, :kind, :role, :topic, :partition_scheme]
    defstruct [:name, :kind, :role, :topic, :partition_scheme, :prompt]

    @type kind :: :agent | :system
    @type partition_scheme ::
            :single
            | {:field, atom()}
            | {:hash, atom()}

    @type t :: %__MODULE__{
            name: binary(),
            kind: kind(),
            role: binary(),
            topic: binary(),
            partition_scheme: partition_scheme(),
            prompt: binary() | nil
          }
  end

  @enforce_keys [:cells]
  defstruct [:cells]

  @type t :: %__MODULE__{cells: [Cell.t()]}

  @spec load(Path.t() | nil) :: t()
  def load(path \\ nil) do
    path = path || default_path()
    {raw, _bindings} = Code.eval_file(path)
    from_raw!(raw)
  end

  @spec from_raw!(map()) :: t()
  def from_raw!(raw) when is_map(raw) do
    cells =
      raw
      |> Map.fetch!(:cells)
      |> Enum.map(&to_cell!/1)

    manifest = %__MODULE__{cells: cells}
    validate!(manifest)
    manifest
  end

  @spec cells(t()) :: [Cell.t()]
  def cells(%__MODULE__{cells: cells}), do: cells

  @spec fetch_cell!(t(), binary()) :: Cell.t()
  def fetch_cell!(%__MODULE__{cells: cells}, name) when is_binary(name) do
    case Enum.find(cells, &(&1.name == name)) do
      nil -> raise ArgumentError, "cell #{inspect(name)} not declared in manifest"
      cell -> cell
    end
  end

  @spec roles(t()) :: [binary()]
  def roles(%__MODULE__{cells: cells}) do
    cells |> Enum.map(& &1.role) |> Enum.uniq()
  end

  @spec topics(t()) :: [binary()]
  def topics(%__MODULE__{cells: cells}) do
    cells |> Enum.map(& &1.topic) |> Enum.uniq()
  end

  @spec default_path() :: Path.t()
  def default_path do
    Path.join(swarm_dir(), "manifest.exs")
  end

  @spec swarm_dir() :: Path.t()
  def swarm_dir do
    Application.get_env(:colony_core, :swarm_dir, "swarm")
  end

  defp to_cell!(%{} = m) do
    %Cell{
      name: fetch_string!(m, :name),
      kind: Map.fetch!(m, :kind),
      role: fetch_string!(m, :role),
      topic: fetch_string!(m, :topic),
      partition_scheme: Map.fetch!(m, :partition_scheme),
      prompt: Map.get(m, :prompt)
    }
  end

  defp fetch_string!(m, key) do
    case Map.fetch!(m, key) do
      v when is_binary(v) and byte_size(v) > 0 -> v
      other -> raise ArgumentError, "manifest cell #{key} must be a non-empty string, got: #{inspect(other)}"
    end
  end

  defp validate!(%__MODULE__{cells: cells}) do
    validate_non_empty!(cells)
    validate_unique_names!(cells)
    Enum.each(cells, &validate_cell!/1)
    :ok
  end

  defp validate_non_empty!([]), do: raise(ArgumentError, "manifest must declare at least one cell")
  defp validate_non_empty!(_), do: :ok

  defp validate_unique_names!(cells) do
    dup =
      cells
      |> Enum.map(& &1.name)
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)

    case dup do
      [] -> :ok
      [{name, _} | _] -> raise ArgumentError, "duplicate cell name #{inspect(name)} in manifest"
    end
  end

  defp validate_cell!(%Cell{} = cell) do
    validate_kind!(cell)
    validate_prompt!(cell)
    validate_partition_scheme!(cell)
  end

  defp validate_kind!(%Cell{kind: kind} = cell) when kind not in [:agent, :system] do
    raise ArgumentError,
          "cell #{inspect(cell.name)} has invalid kind #{inspect(kind)}, expected :agent or :system"
  end

  defp validate_kind!(_), do: :ok

  defp validate_prompt!(%Cell{kind: :agent, prompt: nil} = cell) do
    raise ArgumentError, "agent cell #{inspect(cell.name)} must declare a prompt path"
  end

  defp validate_prompt!(%Cell{kind: :agent, prompt: p} = cell) when not is_binary(p) do
    raise ArgumentError,
          "agent cell #{inspect(cell.name)} prompt must be a string path, got #{inspect(p)}"
  end

  defp validate_prompt!(%Cell{kind: :system, prompt: p} = cell) when not is_nil(p) do
    raise ArgumentError,
          "system cell #{inspect(cell.name)} must not declare a prompt (got #{inspect(p)})"
  end

  defp validate_prompt!(_), do: :ok

  defp validate_partition_scheme!(%Cell{partition_scheme: :single}), do: :ok

  defp validate_partition_scheme!(%Cell{partition_scheme: {scheme, field}})
       when scheme in [:field, :hash] and is_atom(field) and not is_nil(field),
       do: :ok

  defp validate_partition_scheme!(%Cell{} = cell) do
    raise ArgumentError,
          "cell #{inspect(cell.name)} has invalid partition_scheme #{inspect(cell.partition_scheme)}"
  end
end
