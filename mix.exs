defmodule WolframConverter.MixProject do
  use Mix.Project

  def project do
    [
      app: :wolfram_converter,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript(),
      description: "Convert Wolfram Mathematica Notebooks (.nb) to Elixir Livebook (.livemd)",
      package: package()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp escript do
    [main_module: WolframConverter.CLI]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache 2.0"],
      links: %{}
    ]
  end
end
