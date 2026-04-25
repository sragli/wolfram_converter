#!/usr/bin/env elixir

# wolfram_converter.exs
# Usage: elixir wolfram_converter.exs input.nb [output.livemd]

Code.require_file("lib/wolfram_converter/parser.ex", __DIR__)
Code.require_file("lib/wolfram_converter/transformer.ex", __DIR__)
Code.require_file("lib/wolfram_converter.ex", __DIR__)

case System.argv() do
  [input] ->
    output = Path.rootname(input) <> ".livemd"
    case WolframConverter.convert_file(input, output) do
      :ok -> IO.puts("✓ Converted: #{input} → #{output}")
      {:error, reason} -> IO.puts("✗ Error: #{reason}"); System.halt(1)
    end

  [input, output] ->
    case WolframConverter.convert_file(input, output) do
      :ok -> IO.puts("✓ Converted: #{input} → #{output}")
      {:error, reason} -> IO.puts("✗ Error: #{reason}"); System.halt(1)
    end

  _ ->
    IO.puts("Usage: elixir wolfram_converter.exs input.nb [output.livemd]")
    System.halt(1)
end
