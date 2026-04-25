defmodule WolframConverter.CLI do
  @moduledoc """
  Command-line interface for the Wolfram → Livebook converter.

  Build the escript with:

      mix escript.build

  Then run:

      ./wolfram_converter input.nb [output.livemd]
  """

  def main(args) do
    case args do
      ["--help"] ->
        print_usage()

      ["-h"] ->
        print_usage()

      [input] ->
        output = Path.rootname(input) <> ".livemd"
        run(input, output)

      [input, output] ->
        run(input, output)

      [] ->
        IO.puts(:stderr, "Error: no input file specified.\n")
        print_usage()
        System.halt(1)

      _ ->
        IO.puts(:stderr, "Error: unexpected arguments.\n")
        print_usage()
        System.halt(1)
    end
  end

  defp run(input, output) do
    case WolframConverter.convert_file(input, output) do
      :ok ->
        IO.puts("✓ Converted successfully: #{input} → #{output}")

      {:error, :enoent} ->
        IO.puts(:stderr, "Error: file not found: #{input}")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp print_usage do
    IO.puts("""
    wolfram_converter — Convert Wolfram Notebook (.nb) to Elixir Livebook (.livemd)

    Usage:
      wolfram_converter <input.nb> [output.livemd]

    Arguments:
      input.nb        Path to the Wolfram Notebook file
      output.livemd   (optional) Output path; defaults to <input>.livemd

    Options:
      -h, --help      Show this help message
    """)
  end
end
