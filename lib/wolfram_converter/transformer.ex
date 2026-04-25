defmodule WolframConverter.Transformer do
  @moduledoc """
  Transforms a list of parsed `%Cell{}` structs into a Livebook `.livemd` string.

  ## Livebook Format

  A `.livemd` file is a Markdown file with a specific structure:

      # Notebook Title

      ```elixir
      Mix.install([])
      ```

      ## Section

      Markdown paragraph text.

      ```elixir
      # Elixir code cell
      1 + 1
      ```

  Code cells are fenced with ` ```elixir ` / ` ``` `.
  Markdown cells contain standard CommonMark Markdown.

  ## Cell Grouping Strategy

  Consecutive `output` / `print` / `echo` cells that follow a `code` cell are
  appended to that code cell as `# => ...` comments, rather than creating
  separate cells. This matches the typical Wolfram workflow where outputs appear
  directly below their input cells.
  """

  alias WolframConverter.Parser.Cell

  @livebook_header """
  <!-- livebook:{"app_settings":{"slug":"wolfram_import"}} -->

  """

  @doc """
  Converts a list of `%Cell{}` structs to a Livebook `.livemd` string.
  """
  @spec to_livemd([Cell.t()]) :: String.t()
  def to_livemd(cells) do
    cells
    |> group_with_outputs()
    |> Enum.map(&render_group/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> then(&(@livebook_header <> &1))
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  # ── Grouping ────────────────────────────────────────────────────────────────

  # Group each code cell together with any immediately following output/print/echo
  # cells, yielding `{:code_group, code_cell, [output_cells]}` or `{:single, cell}`.
  defp group_with_outputs(cells) do
    do_group(cells, [])
  end

  defp do_group([], acc), do: Enum.reverse(acc)

  defp do_group([%Cell{type: code_type} = code | rest], acc)
       when code_type in [:code] do
    {outputs, remaining} = take_output_cells(rest)
    do_group(remaining, [{:code_group, code, outputs} | acc])
  end

  defp do_group([cell | rest], acc) do
    # Skip standalone output cells that were not preceded by a code cell
    if cell.type in [:output, :print, :echo, :message] do
      do_group(rest, acc)
    else
      do_group(rest, [{:single, cell} | acc])
    end
  end

  defp take_output_cells(cells) do
    Enum.split_while(cells, fn %Cell{type: t} ->
      t in [:output, :print, :echo, :message]
    end)
  end

  # ── Rendering ───────────────────────────────────────────────────────────────

  defp render_group({:single, cell}), do: render_cell(cell)
  defp render_group({:code_group, code, outputs}), do: render_code_group(code, outputs)

  defp render_code_group(code, []) do
    render_code_cell(code.content)
  end

  defp render_code_group(code, outputs) do
    output_comments =
      outputs
      |> Enum.flat_map(fn cell ->
        prefix = output_prefix(cell.type)

        cell.content
        |> String.split("\n")
        |> Enum.map(fn line -> "#{prefix}#{line}" end)
      end)
      |> Enum.join("\n")

    code_with_output = code.content <> "\n\n" <> output_comments
    render_code_cell(code_with_output)
  end

  defp output_prefix(:print), do: "# [Print] "
  defp output_prefix(:echo), do: "# [Echo] "
  defp output_prefix(:message), do: "# [Message] "
  defp output_prefix(_), do: "# => "

  defp render_cell(%Cell{type: type, content: content}) do
    case type do
      :title -> "# #{content}"
      :subtitle -> "## #{content}"
      :subsubtitle -> "### #{content}"
      :chapter -> "## #{content}"
      :subchapter -> "### #{content}"
      :section -> "## #{content}"
      :subsection -> "### #{content}"
      :subsubsection -> "#### #{content}"
      :subsubsubsection -> "##### #{content}"
      :text -> render_text(content)
      :item -> "- #{content}"
      :item_paragraph -> "  #{content}"
      :subitem -> "  - #{content}"
      :subitem_paragraph -> "    #{content}"
      :code -> render_code_cell(content)
      # handled in code_group
      :output -> ""
      :print -> ""
      :echo -> ""
      :message -> ""
      :comment -> render_comment(content)
      :inline_formula -> "`#{content}`"
      :display_formula -> "\n$$\n#{content}\n$$\n"
      :author -> "_#{String.trim(content)}_"
      :institution -> "_#{String.trim(content)}_"
      :date -> "_#{String.trim(content)}_"
      :abstract -> render_text(content)
      :reference -> "- #{String.trim(content)}"
      :figure_caption -> "_#{render_text(content)}_"
      :unknown -> if String.trim(content) == "", do: "", else: render_text(content)
    end
  end

  defp render_text(content) do
    trimmed = String.trim(content)
    # Markdown tables start with `|` — don't collapse their newlines
    if String.starts_with?(trimmed, "|") do
      trimmed
    else
      trimmed
      |> convert_wolfram_inline_markup()
    end
  end

  defp render_code_cell(content) do
    code =
      content
      |> String.trim()
      |> convert_wolfram_syntax_hints()

    "```elixir\n#{code}\n```"
  end

  defp render_comment(content) do
    lines =
      content
      |> String.split("\n")
      |> Enum.map(&"> #{&1}")
      |> Enum.join("\n")

    "> **Note**\n>\n#{lines}"
  end

  # ── Wolfram → Markdown Inline Markup ────────────────────────────────────────

  # Convert some Wolfram-specific inline patterns to Markdown equivalents.
  defp convert_wolfram_inline_markup(text) do
    text
    # Wolfram line-continuation: trailing backslash before newline means the string
    # was split across source lines — join them with a space.
    |> String.replace(~r/\\\n/, " ")
    # Multi-line text: collapse single newlines into spaces; keep double newlines
    # as paragraph breaks.
    |> String.replace(~r/(?<!\n)\n(?!\n)/, " ")
    # Collapse runs of spaces introduced above
    |> String.replace(~r/ {2,}/, " ")
    |> String.trim()
  end

  # ── Wolfram → Elixir Syntax Hints ───────────────────────────────────────────

  # Annotate common Wolfram constructs with Elixir equivalents.
  # This is best-effort; full transpilation is out of scope, but we add
  # helpful comments so the user knows what to translate.
  defp convert_wolfram_syntax_hints(code) do
    code
    # Add a header comment if the code looks like Wolfram/Mathematica
    |> then(fn c ->
      if looks_like_wolfram?(c) do
        "# TODO: Translate from Wolfram/Mathematica to Elixir\n" <>
          "# Original Wolfram code:\n" <>
          add_comment_prefix(c)
      else
        c
      end
    end)
  end

  defp looks_like_wolfram?(code) do
    wolfram_patterns = [
      # FunctionName[args]
      ~r/\w+\[.*\]/s,
      # ReplaceAll Rule
      ~r/:>/,
      # Rule
      ~r/->/,
      # ReplaceAll /.
      ~r/\/\./,
      # Part [[]]
      ~r/\[\[.*\]\]/,
      # Apply @
      ~r/@/,
      # Apply @@
      ~r/@@/,
      # Map /@
      ~r/\/@/,
      ~r/Table\[/i,
      ~r/Do\[/i,
      ~r/Module\[/i,
      ~r/Plot\[/i
    ]

    Enum.any?(wolfram_patterns, &Regex.match?(&1, code))
  end

  defp add_comment_prefix(code) do
    code
    |> String.split("\n")
    |> Enum.map(&"# #{&1}")
    |> Enum.join("\n")
  end
end
