defmodule ColonyAdapterK8s.Fixtures do
  @moduledoc """
  Lists and loads the Kubernetes Event JSON fixtures shipped with this
  adapter. Fixtures live in `priv/fixtures/*.json` and are plain vendor
  payloads — exactly the shape a real k8s API server would produce.
  """

  @doc """
  Slugs of all shipped fixtures (filename without `.json`), sorted.
  """
  @spec list() :: [binary()]
  def list do
    dir = fixtures_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&String.replace_trailing(&1, ".json", ""))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc """
  Load a fixture by slug. Returns the decoded JSON as a map.
  """
  @spec load(binary()) :: {:ok, map()} | {:error, term()}
  def load(name) when is_binary(name) do
    path = Path.join(fixtures_dir(), name <> ".json")

    with {:ok, body} <- File.read(path),
         {:ok, payload} <- Jason.decode(body) do
      {:ok, payload}
    end
  end

  @doc """
  Absolute path to the adapter's fixtures directory.
  """
  @spec fixtures_dir() :: Path.t()
  def fixtures_dir do
    Path.join(:code.priv_dir(:colony_adapter_k8s) |> to_string(), "fixtures")
  end
end
