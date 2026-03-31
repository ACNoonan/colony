defmodule Colony.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: [],
      aliases: aliases()
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
