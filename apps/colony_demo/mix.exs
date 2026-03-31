defmodule ColonyDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :colony_demo,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ColonyDemo.Application, []}
    ]
  end

  defp deps do
    [
      {:colony_core, in_umbrella: true},
      {:colony_cell, in_umbrella: true},
      {:colony_kafka, in_umbrella: true}
    ]
  end
end
