defmodule WolframConverter.Parser do
  @moduledoc """
  Parses Wolfram Notebook (.nb) files into an intermediate cell representation.

  Wolfram Notebooks are text files containing nested Mathematica expression syntax.
  The top-level structure is a `Notebook[{...cells...}, options]` expression where
  each cell is a `Cell[content, "StyleName", options...]` expression.

  Cell content can be:
    - A plain string `"some text"`
    - A `TextData[{...}]` expression (styled text fragments)
    - A `BoxData[...]` expression (typeset/code content)
    - A `RowBox[{...}]` expression (inline expressions)

  This parser extracts a flat list of `%Cell{}` structs from the notebook.
  """

  defmodule Cell do
    @moduledoc "Represents a parsed Wolfram Notebook cell."
    defstruct [:type, :content, :metadata]

    @type t :: %__MODULE__{
            type: atom(),
            content: String.t(),
            metadata: map()
          }
  end

  @doc """
  Parses a Wolfram Notebook string and returns a list of `%Cell{}` structs.
  """
  @spec parse(String.t()) :: [Cell.t()]
  def parse(content) do
    content
    |> normalize_whitespace()
    |> extract_notebook_body()
    |> split_top_level_exprs()
    |> Enum.flat_map(fn raw ->
      case parse_cell(raw) do
        nil -> []
        cells when is_list(cells) -> cells
        cell -> [cell]
      end
    end)
  end

  # ── Preprocessing ──────────────────────────────────────────────────────────

  defp normalize_whitespace(content) do
    content
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  # Extract the body between Notebook[{ ... }, ...]
  # Uses binary search to avoid catastrophic regex backtracking on large files.
  defp extract_notebook_body(content) do
    case :binary.match(content, "Notebook[") do
      {pos, len} ->
        after_keyword = binary_part(content, pos + len, byte_size(content) - pos - len)

        case skip_whitespace_to_brace(after_keyword, 0) do
          {:ok, brace_offset} ->
            inner_start = pos + len + brace_offset + 1

            case find_matching_brace(content, inner_start, 1) do
              {:ok, inner_end} ->
                binary_part(content, inner_start, inner_end - inner_start)

              :error ->
                binary_part(content, inner_start, byte_size(content) - inner_start)
            end

          :error ->
            content
        end

      :nomatch ->
        case :binary.match(content, "{") do
          {pos, _} ->
            inner_start = pos + 1

            case find_matching_brace(content, inner_start, 1) do
              {:ok, inner_end} -> binary_part(content, inner_start, inner_end - inner_start)
              :error -> binary_part(content, inner_start, byte_size(content) - inner_start)
            end

          :nomatch ->
            content
        end
    end
  end

  defp skip_whitespace_to_brace(bin, pos) do
    if pos >= byte_size(bin) do
      :error
    else
      case :binary.at(bin, pos) do
        ?{ -> {:ok, pos}
        c when c in [?\s, ?\t, ?\n, ?\r] -> skip_whitespace_to_brace(bin, pos + 1)
        _ -> :error
      end
    end
  end

  # Find the position of the closing `}` or `]` that matches an opening at
  # the given depth, starting from `pos`. Handles string literals.
  defp find_matching_brace(str, pos, depth), do: do_find_brace(str, pos, depth, byte_size(str))

  defp do_find_brace(_str, pos, _depth, size) when pos >= size, do: :error

  defp do_find_brace(str, pos, depth, size) do
    case :binary.at(str, pos) do
      ?" ->
        case do_find_str_end(str, pos + 1, size) do
          {:ok, end_pos} -> do_find_brace(str, end_pos, depth, size)
          :error -> :error
        end

      c when c in [?[, ?{] ->
        do_find_brace(str, pos + 1, depth + 1, size)

      c when c in [?], ?}] and depth == 1 ->
        {:ok, pos}

      c when c in [?], ?}] ->
        do_find_brace(str, pos + 1, depth - 1, size)

      _ ->
        do_find_brace(str, pos + 1, depth, size)
    end
  end

  defp do_find_str_end(_str, pos, size) when pos >= size, do: :error

  defp do_find_str_end(str, pos, size) do
    case :binary.at(str, pos) do
      ?\\ -> do_find_str_end(str, pos + 2, size)
      ?" -> {:ok, pos + 1}
      _ -> do_find_str_end(str, pos + 1, size)
    end
  end

  # ── Top-Level Expression Splitting ─────────────────────────────────────────

  # Walk bytes tracking bracket depth and string state.
  # Emits a token each time a `]` or `}` closes depth back to 0,
  # or at top-level commas.
  # Uses binary_part for O(1) token extraction (no char-list building).
  defp split_top_level_exprs(body) do
    do_split_top(body, body, 0, [], 0, false, false)
  end

  defp do_split_top(<<>>, orig, tok_start, acc, _depth, _in_str, _esc) do
    len = byte_size(orig) - tok_start
    token = binary_part(orig, tok_start, len) |> String.trim()

    result =
      if token == "" or token == ",", do: Enum.reverse(acc), else: Enum.reverse([token | acc])

    Enum.reject(result, &(&1 == "" or &1 == ","))
  end

  defp do_split_top(<<char, rest::binary>>, orig, tok_start, acc, depth, in_str, esc) do
    pos = byte_size(orig) - byte_size(rest) - 1

    cond do
      char == ?\\ and in_str and not esc ->
        do_split_top(rest, orig, tok_start, acc, depth, true, true)

      esc ->
        do_split_top(rest, orig, tok_start, acc, depth, in_str, false)

      char == ?" ->
        do_split_top(rest, orig, tok_start, acc, depth, not in_str, false)

      in_str ->
        do_split_top(rest, orig, tok_start, acc, depth, true, false)

      char in [?[, ?{] ->
        do_split_top(rest, orig, tok_start, acc, depth + 1, false, false)

      char in [?], ?}] ->
        new_depth = depth - 1
        new_pos = pos + 1

        if new_depth == 0 do
          token = binary_part(orig, tok_start, new_pos - tok_start) |> String.trim()
          do_split_top(rest, orig, new_pos, [token | acc], 0, false, false)
        else
          do_split_top(rest, orig, tok_start, acc, new_depth, false, false)
        end

      char == ?, and depth == 0 ->
        token = binary_part(orig, tok_start, pos - tok_start) |> String.trim()
        new_acc = if token == "" or token == ",", do: acc, else: [token | acc]
        do_split_top(rest, orig, pos + 1, new_acc, 0, false, false)

      true ->
        do_split_top(rest, orig, tok_start, acc, depth, false, false)
    end
  end

  # ── Cell Parsing ────────────────────────────────────────────────────────────

  defp parse_cell(raw) do
    cond do
      String.starts_with?(raw, "Cell[") -> parse_cell_expr(raw)
      String.starts_with?(raw, "CellGroupData[") -> extract_cell_group(raw)
      String.starts_with?(raw, "(*") -> parse_comment_cell(raw)
      true -> nil
    end
  end

  # Parses: Cell[content, "StyleName", options...]
  defp parse_cell_expr(raw) do
    inner =
      raw
      |> String.replace_prefix("Cell[", "")
      |> then(fn s ->
        if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s
      end)

    args = split_args(inner)

    case args do
      [content_raw | [style_raw | _rest]] ->
        content_trimmed = String.trim(content_raw)

        if String.starts_with?(content_trimmed, "CellGroupData[") do
          extract_cell_group(content_trimmed)
        else
          style = extract_string(style_raw)

          content =
            if style in ["InlineFormula", "DisplayFormula", "DisplayFormulaNumbered"] do
              extract_math_content(content_raw)
            else
              extract_cell_content(content_raw)
            end

          type = style_to_type(style)
          %Cell{type: type, content: content, metadata: %{raw_style: style}}
        end

      [content_raw] ->
        content_trimmed = String.trim(content_raw)

        if String.starts_with?(content_trimmed, "CellGroupData[") do
          extract_cell_group(content_trimmed)
        else
          content = extract_cell_content(content_raw)
          %Cell{type: :unknown, content: content, metadata: %{}}
        end

      _ ->
        nil
    end
  end

  # Recursively extracts cells from CellGroupData[{cells...}, state]
  defp extract_cell_group(raw) do
    inner =
      raw
      |> String.replace_prefix("CellGroupData[", "")
      |> then(fn s ->
        if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s
      end)
      |> String.trim()

    args = split_args(inner)

    case args do
      [cells_list_raw | _] ->
        cells_list_raw = String.trim(cells_list_raw)

        body =
          if String.starts_with?(cells_list_raw, "{") and String.ends_with?(cells_list_raw, "}") do
            cells_list_raw |> String.slice(1..-2//1)
          else
            cells_list_raw
          end

        body
        |> split_top_level_exprs()
        |> Enum.flat_map(fn raw ->
          case parse_cell(raw) do
            nil -> []
            cells when is_list(cells) -> cells
            cell -> [cell]
          end
        end)

      _ ->
        []
    end
  end

  defp parse_comment_cell(raw) do
    content =
      raw
      |> String.replace(~r/^\(\*\s*/, "")
      |> String.replace(~r/\s*\*\)$/, "")
      |> String.trim()

    %Cell{type: :comment, content: content, metadata: %{}}
  end

  # ── Argument Splitting ──────────────────────────────────────────────────────

  # Same as split_top_level_exprs but does NOT emit on `]`/`}` reaching depth 0
  # — keeps brackets as part of the token and only splits on top-level commas.
  defp split_args(str) do
    do_split_args(str, str, 0, [], 0, false, false)
  end

  defp do_split_args(<<>>, orig, tok_start, acc, _depth, _in_str, _esc) do
    len = byte_size(orig) - tok_start
    token = binary_part(orig, tok_start, len) |> String.trim()
    result = if token == "", do: Enum.reverse(acc), else: Enum.reverse([token | acc])
    Enum.reject(result, &(&1 == ""))
  end

  defp do_split_args(<<char, rest::binary>>, orig, tok_start, acc, depth, in_str, esc) do
    pos = byte_size(orig) - byte_size(rest) - 1

    cond do
      char == ?\\ and in_str and not esc ->
        do_split_args(rest, orig, tok_start, acc, depth, true, true)

      esc ->
        do_split_args(rest, orig, tok_start, acc, depth, in_str, false)

      char == ?" ->
        do_split_args(rest, orig, tok_start, acc, depth, not in_str, false)

      in_str ->
        do_split_args(rest, orig, tok_start, acc, depth, true, false)

      char in [?[, ?{] ->
        do_split_args(rest, orig, tok_start, acc, depth + 1, false, false)

      char in [?], ?}] ->
        do_split_args(rest, orig, tok_start, acc, depth - 1, false, false)

      char == ?, and depth == 0 ->
        token = binary_part(orig, tok_start, pos - tok_start) |> String.trim()
        new_acc = if token == "", do: acc, else: [token | acc]
        do_split_args(rest, orig, pos + 1, new_acc, 0, false, false)

      true ->
        do_split_args(rest, orig, tok_start, acc, depth, false, false)
    end
  end

  # ── Content Extraction ──────────────────────────────────────────────────────

  defp extract_cell_content(raw) do
    raw = String.trim(raw)

    cond do
      Regex.match?(~r/^".*"$/s, raw) ->
        extract_string(raw)

      String.starts_with?(raw, "TextData[") ->
        extract_text_data(raw)

      String.starts_with?(raw, "BoxData[") ->
        extract_box_data(raw)

      String.starts_with?(raw, "RowBox[") ->
        extract_row_box(raw)

      true ->
        raw
        |> String.replace(~r/^\w+\[/, "")
        |> then(fn s ->
          if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s
        end)
        |> unescape_string()
        |> String.trim()
    end
  end

  # TextData[{"text", StyleBox["styled", opts], ...}]
  defp extract_text_data(raw) do
    inner =
      raw
      |> String.replace_prefix("TextData[", "")
      |> then(fn s ->
        if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s
      end)
      |> String.trim()

    inner =
      if String.starts_with?(inner, "{") and String.ends_with?(inner, "}") do
        inner |> String.slice(1..-2//1) |> String.trim()
      else
        inner
      end

    inner
    |> split_args()
    |> Enum.map(&extract_text_fragment/1)
    |> Enum.join("")
    |> String.trim()
  end

  defp extract_text_fragment(raw) do
    raw = String.trim(raw)

    cond do
      Regex.match?(~r/^".*"$/s, raw) ->
        extract_string(raw)

      String.starts_with?(raw, "StyleBox[") ->
        inner =
          raw
          |> String.replace_prefix("StyleBox[", "")
          |> then(fn s ->
            if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s
          end)

        args = split_args(inner)
        text = List.first(args, "") |> extract_text_fragment()
        rest = Enum.drop(args, 1)
        is_bold = Enum.any?(rest, &String.contains?(&1, "\"Bold\""))
        is_italic = Enum.any?(rest, &String.contains?(&1, "\"Italic\""))

        text
        |> then(fn t -> if is_bold, do: "**#{t}**", else: t end)
        |> then(fn t -> if is_italic, do: "_#{t}_", else: t end)

      String.starts_with?(raw, "ButtonBox[") or String.starts_with?(raw, "TagBox[") ->
        inner =
          raw
          |> String.replace(~r/^\w+\[/, "")
          |> then(fn s ->
            if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s
          end)

        args = split_args(inner)
        List.first(args, "") |> extract_text_fragment()

      String.starts_with?(raw, "RowBox[") ->
        extract_row_box(raw)

      # Nested Cell[BoxData[...], opts] inside TextData — math → $LaTeX$, other → plain text
      String.starts_with?(raw, "Cell[") ->
        inner =
          raw
          |> String.replace_prefix("Cell[", "")
          |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

        args = split_args(inner)
        first = List.first(args, "") |> String.trim()

        if String.starts_with?(first, "BoxData[") do
          latex =
            first
            |> String.replace_prefix("BoxData[", "")
            |> then(fn s ->
              if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s
            end)
            |> String.trim()
            |> box_to_latex()

          if latex != "", do: "$#{latex}$", else: ""
        else
          extract_cell_content(first)
        end

      String.starts_with?(raw, "FormBox[") ->
        inner =
          raw
          |> String.replace_prefix("FormBox[", "")
          |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

        split_args(inner) |> List.first("") |> extract_text_fragment()

      # CounterBox — auto-numbering placeholder, skip it (number is managed by Wolfram)
      String.starts_with?(raw, "CounterBox[") ->
        ""

      true ->
        raw |> unescape_string()
    end
  end

  defp extract_box_data(raw) do
    inner =
      raw
      |> String.replace_prefix("BoxData[", "")
      |> then(fn s ->
        if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s
      end)
      |> String.trim()

    extract_box_content(inner)
  end

  defp extract_box_content(raw) do
    raw = String.trim(raw)

    cond do
      Regex.match?(~r/^".*"$/s, raw) ->
        extract_string(raw)

      String.starts_with?(raw, "RowBox[") ->
        extract_row_box(raw)

      String.starts_with?(raw, "FractionBox[") ->
        extract_fraction_box(raw)

      String.starts_with?(raw, "SuperscriptBox[") ->
        extract_superscript_box(raw)

      String.starts_with?(raw, "SubscriptBox[") ->
        extract_subscript_box(raw)

      String.starts_with?(raw, "SubsuperscriptBox[") ->
        extract_subsuperscript_box(raw)

      String.starts_with?(raw, "UnderoverscriptBox[") ->
        extract_underoverscript_box(raw)

      String.starts_with?(raw, "OverscriptBox[") ->
        extract_overscript_box(raw)

      String.starts_with?(raw, "UnderscriptBox[") ->
        extract_underscript_box(raw)

      String.starts_with?(raw, "SqrtBox[") ->
        inner =
          raw
          |> String.replace_prefix("SqrtBox[", "")
          |> then(fn s ->
            if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s
          end)

        "√(#{extract_box_content(inner)})"

      String.starts_with?(raw, "RadicalBox[") ->
        inner =
          raw
          |> String.replace_prefix("RadicalBox[", "")
          |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

        case split_args(inner) do
          [base, n | _] -> "(#{extract_box_content(base)})^(1/#{extract_box_content(n)})"
          [base] -> "√(#{extract_box_content(base)})"
          _ -> ""
        end

      # FormBox[content, TraditionalForm/...] — just extract the content
      String.starts_with?(raw, "FormBox[") ->
        inner =
          raw
          |> String.replace_prefix("FormBox[", "")
          |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

        split_args(inner) |> List.first("") |> extract_box_content()

      # StyleBox[content, FontWeight->"Bold", ...]
      String.starts_with?(raw, "StyleBox[") ->
        inner =
          raw
          |> String.replace_prefix("StyleBox[", "")
          |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

        args = split_args(inner)
        text = List.first(args, "") |> extract_box_content()
        rest = Enum.drop(args, 1)
        is_bold = Enum.any?(rest, &String.contains?(&1, "\"Bold\""))
        is_italic = Enum.any?(rest, &String.contains?(&1, "\"Italic\""))

        text
        |> then(fn t -> if is_bold, do: "**#{t}**", else: t end)
        |> then(fn t -> if is_italic, do: "_#{t}_", else: t end)

      # InterpretationBox[display, interpretation, opts] — use display form
      String.starts_with?(raw, "InterpretationBox[") ->
        inner =
          raw
          |> String.replace_prefix("InterpretationBox[", "")
          |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

        first = split_args(inner) |> List.first("")
        first_trimmed = String.trim(first)

        if String.starts_with?(first_trimmed, "Cell[") do
          extract_text_fragment(first_trimmed)
        else
          extract_box_content(first_trimmed)
        end

      # TagBox[content, tag, opts] — extract content
      String.starts_with?(raw, "TagBox[") ->
        inner =
          raw
          |> String.replace_prefix("TagBox[", "")
          |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

        split_args(inner) |> List.first("") |> extract_box_content()

      # TooltipBox[content, tooltip] — just the visible content
      String.starts_with?(raw, "TooltipBox[") ->
        inner =
          raw
          |> String.replace_prefix("TooltipBox[", "")
          |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

        split_args(inner) |> List.first("") |> extract_box_content()

      # ButtonBox[label, opts] — just the label
      String.starts_with?(raw, "ButtonBox[") ->
        inner =
          raw
          |> String.replace_prefix("ButtonBox[", "")
          |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

        split_args(inner) |> List.first("") |> extract_box_content()

      # Passthrough containers — extract their first argument
      String.starts_with?(raw, "PaneBox[") or
        String.starts_with?(raw, "PanelBox[") or
        String.starts_with?(raw, "FrameBox[") or
        String.starts_with?(raw, "AdjustmentBox[") or
        String.starts_with?(raw, "ItemBox[") or
        String.starts_with?(raw, "HighlightActionBox[") or
          String.starts_with?(raw, "OverlayBox[") ->
        inner =
          raw
          |> String.replace(~r/^\w+\[/, "")
          |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

        split_args(inner) |> List.first("") |> extract_box_content()

      # GridBox[{{r1c1, r1c2}, {r2c1, r2c2}}, opts] — render as markdown table
      String.starts_with?(raw, "GridBox[") ->
        extract_grid_box(raw)

      # CounterBox["name"] — substitute a placeholder label
      String.starts_with?(raw, "CounterBox[") ->
        inner =
          raw
          |> String.replace_prefix("CounterBox[", "")
          |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

        label = split_args(inner) |> List.first("") |> extract_string()
        "[#{label} #]"

      # SpacerBox — render as a space
      String.starts_with?(raw, "SpacerBox[") ->
        " "

      # Graphics/image boxes — render as a placeholder
      String.starts_with?(raw, "GraphicsBox[") or
        String.starts_with?(raw, "Graphics3DBox[") or
          String.starts_with?(raw, "RasterBox[") ->
        "[figure]"

      # Dynamic/interactive boxes — no useful static content
      String.starts_with?(raw, "DynamicBox[") or
        String.starts_with?(raw, "DynamicModuleBox[") or
        String.starts_with?(raw, "AnimatorBox[") or
          String.starts_with?(raw, "PaneSelectorBox[") ->
        ""

      # Nested Cell[BoxData[...], opts] as box content
      String.starts_with?(raw, "Cell[") ->
        inner =
          raw
          |> String.replace_prefix("Cell[", "")
          |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

        split_args(inner) |> List.first("") |> String.trim() |> extract_cell_content()

      true ->
        stripped =
          raw
          |> String.replace(~r/^\w+\[/, "")
          |> then(fn s ->
            if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s
          end)

        if stripped == raw do
          # No outer function call to strip — content is raw data (e.g. compressed
          # image data, {list}, etc.). Return empty so we don't infinite-loop.
          ""
        else
          extract_box_content(stripped)
        end
    end
  end

  defp extract_row_box(raw) do
    inner =
      raw
      |> String.replace_prefix("RowBox[{", "")
      |> then(fn s ->
        if String.ends_with?(s, "}]"), do: String.slice(s, 0..-3//1), else: s
      end)
      |> String.trim()

    inner
    |> split_args()
    |> Enum.map(&extract_box_content/1)
    |> Enum.join("")
  end

  defp extract_fraction_box(raw) do
    inner =
      raw
      |> String.replace_prefix("FractionBox[", "")
      |> then(fn s ->
        if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s
      end)

    case split_args(inner) do
      [num, den | _] -> "(#{extract_box_content(num)})/(#{extract_box_content(den)})"
      [num] -> "#{extract_box_content(num)}/?"
      _ -> raw
    end
  end

  defp extract_superscript_box(raw) do
    inner =
      raw
      |> String.replace_prefix("SuperscriptBox[", "")
      |> then(fn s ->
        if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s
      end)

    case split_args(inner) do
      [base, exp | _] -> "#{extract_box_content(base)}^#{extract_box_content(exp)}"
      _ -> raw
    end
  end

  defp extract_subscript_box(raw) do
    inner =
      raw
      |> String.replace_prefix("SubscriptBox[", "")
      |> then(fn s ->
        if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s
      end)

    case split_args(inner) do
      [base, sub | _] -> "#{extract_box_content(base)}_#{extract_box_content(sub)}"
      _ -> raw
    end
  end

  defp extract_subsuperscript_box(raw) do
    inner =
      raw
      |> String.replace_prefix("SubsuperscriptBox[", "")
      |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

    case split_args(inner) do
      [base, sub, sup | _] ->
        "#{extract_box_content(base)}_#{extract_box_content(sub)}^#{extract_box_content(sup)}"

      [base, sub] ->
        "#{extract_box_content(base)}_#{extract_box_content(sub)}"

      _ ->
        raw
    end
  end

  defp extract_underoverscript_box(raw) do
    inner =
      raw
      |> String.replace_prefix("UnderoverscriptBox[", "")
      |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

    case split_args(inner) do
      [base, under, over | _] ->
        "#{extract_box_content(base)}_#{extract_box_content(under)}^#{extract_box_content(over)}"

      [base, under] ->
        "#{extract_box_content(base)}_#{extract_box_content(under)}"

      _ ->
        raw
    end
  end

  defp extract_overscript_box(raw) do
    inner =
      raw
      |> String.replace_prefix("OverscriptBox[", "")
      |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

    case split_args(inner) do
      [base, over | _] -> "#{extract_box_content(base)}^#{extract_box_content(over)}"
      _ -> raw
    end
  end

  defp extract_underscript_box(raw) do
    inner =
      raw
      |> String.replace_prefix("UnderscriptBox[", "")
      |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)

    case split_args(inner) do
      [base, under | _] -> "#{extract_box_content(base)}_#{extract_box_content(under)}"
      _ -> raw
    end
  end

  # GridBox[{{r1c1, r1c2, ...}, {r2c1, ...}}, opts] → Markdown table
  defp extract_grid_box(raw) do
    inner =
      raw
      |> String.replace_prefix("GridBox[", "")
      |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)
      |> String.trim()

    rows_raw =
      if String.starts_with?(inner, "{") do
        # First argument is the list of rows
        split_args(inner) |> List.first("") |> String.trim()
      else
        inner
      end

    # Strip outer { }
    rows_raw =
      if String.starts_with?(rows_raw, "{") and String.ends_with?(rows_raw, "}") do
        String.slice(rows_raw, 1..-2//1)
      else
        rows_raw
      end

    rows =
      rows_raw
      |> split_top_level_exprs()
      |> Enum.map(fn row_raw ->
        row_raw = String.trim(row_raw)

        cells =
          if String.starts_with?(row_raw, "{") and String.ends_with?(row_raw, "}") do
            row_raw |> String.slice(1..-2//1) |> split_args()
          else
            [row_raw]
          end

        cells |> Enum.map(fn c -> String.trim(c) |> extract_box_content() end)
      end)

    case rows do
      [] ->
        ""

      [header | body] ->
        header_line = "| " <> Enum.join(header, " | ") <> " |"
        sep_line = "| " <> Enum.map_join(header, " | ", fn _ -> "---" end) <> " |"

        body_lines =
          Enum.map(body, fn cols -> "| " <> Enum.join(cols, " | ") <> " |" end)

        ([header_line, sep_line] ++ body_lines) |> Enum.join("\n")
    end
  end

  # ── Math Box → LaTeX ────────────────────────────────────────────────────────

  # Unwrap BoxData and convert its content to LaTeX for formula cells.
  defp extract_math_content(raw) do
    raw = String.trim(raw)

    if String.starts_with?(raw, "BoxData[") do
      raw
      |> String.replace_prefix("BoxData[", "")
      |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)
      |> String.trim()
      |> box_to_latex()
    else
      extract_cell_content(raw)
    end
  end

  # Converts a Wolfram box expression to a LaTeX string.
  # Used for inline/display formula cells and Cell[BoxData[...]] in text.
  defp box_to_latex(raw) do
    raw = String.trim(raw)

    cond do
      raw == "" ->
        ""

      Regex.match?(~r/^".*"$/s, raw) ->
        raw |> extract_string() |> to_latex_atom()

      String.starts_with?(raw, "RowBox[") ->
        inner =
          raw
          |> String.replace_prefix("RowBox[{", "")
          |> then(fn s ->
            if String.ends_with?(s, "}]"), do: String.slice(s, 0..-3//1), else: s
          end)
          |> String.trim()

        inner |> split_args() |> Enum.map(&box_to_latex/1) |> Enum.join("")

      String.starts_with?(raw, "FractionBox[") ->
        inner = box_strip(raw, "FractionBox[")

        case split_args(inner) do
          [n, d | _] -> "\\frac{#{box_to_latex(n)}}{#{box_to_latex(d)}}"
          [n] -> "\\frac{#{box_to_latex(n)}}{?}"
          _ -> ""
        end

      String.starts_with?(raw, "SuperscriptBox[") ->
        inner = box_strip(raw, "SuperscriptBox[")

        case split_args(inner) do
          [b, e | _] -> "#{latex_brace(box_to_latex(b))}^{#{box_to_latex(e)}}"
          _ -> ""
        end

      String.starts_with?(raw, "SubscriptBox[") ->
        inner = box_strip(raw, "SubscriptBox[")

        case split_args(inner) do
          [b, s | _] -> "#{latex_brace(box_to_latex(b))}_{#{box_to_latex(s)}}"
          _ -> ""
        end

      String.starts_with?(raw, "SubsuperscriptBox[") ->
        inner = box_strip(raw, "SubsuperscriptBox[")

        case split_args(inner) do
          [b, s, e | _] ->
            "#{latex_brace(box_to_latex(b))}_{#{box_to_latex(s)}}^{#{box_to_latex(e)}}"

          [b, s] ->
            "#{latex_brace(box_to_latex(b))}_{#{box_to_latex(s)}}"

          _ ->
            ""
        end

      String.starts_with?(raw, "UnderoverscriptBox[") ->
        inner = box_strip(raw, "UnderoverscriptBox[")

        case split_args(inner) do
          [b, u, o | _] ->
            "#{latex_brace(box_to_latex(b))}_{#{box_to_latex(u)}}^{#{box_to_latex(o)}}"

          [b, u] ->
            "#{latex_brace(box_to_latex(b))}_{#{box_to_latex(u)}}"

          _ ->
            ""
        end

      String.starts_with?(raw, "OverscriptBox[") ->
        inner = box_strip(raw, "OverscriptBox[")

        case split_args(inner) do
          [b, o | _] ->
            over = box_to_latex(o)
            base = box_to_latex(b)

            case over do
              "_" -> "\\bar{#{latex_brace(base)}}"
              "-" -> "\\bar{#{latex_brace(base)}}"
              "~" -> "\\tilde{#{latex_brace(base)}}"
              "^" -> "\\hat{#{latex_brace(base)}}"
              "." -> "\\dot{#{latex_brace(base)}}"
              _ -> "\\overset{#{over}}{#{latex_brace(base)}}"
            end

          _ ->
            ""
        end

      String.starts_with?(raw, "UnderscriptBox[") ->
        inner = box_strip(raw, "UnderscriptBox[")

        case split_args(inner) do
          [b, u | _] ->
            "\\underset{#{box_to_latex(u)}}{#{latex_brace(box_to_latex(b))}}"

          _ ->
            ""
        end

      String.starts_with?(raw, "SqrtBox[") ->
        inner = box_strip(raw, "SqrtBox[")
        "\\sqrt{#{box_to_latex(inner)}}"

      String.starts_with?(raw, "RadicalBox[") ->
        inner = box_strip(raw, "RadicalBox[")

        case split_args(inner) do
          [base, n | _] -> "\\sqrt[#{box_to_latex(n)}]{#{box_to_latex(base)}}"
          [base] -> "\\sqrt{#{box_to_latex(base)}}"
          _ -> ""
        end

      # Passthrough wrappers: FormBox, StyleBox, TagBox, InterpretationBox, TooltipBox
      String.starts_with?(raw, "FormBox[") or
        String.starts_with?(raw, "StyleBox[") or
        String.starts_with?(raw, "TagBox[") or
        String.starts_with?(raw, "InterpretationBox[") or
          String.starts_with?(raw, "TooltipBox[") ->
        inner =
          raw
          |> String.replace(~r/^\w+\[/, "")
          |> then(fn s ->
            if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s
          end)

        split_args(inner) |> List.first("") |> box_to_latex()

      # {list} — join parts
      String.starts_with?(raw, "{") and String.ends_with?(raw, "}") ->
        raw
        |> String.slice(1..-2//1)
        |> split_args()
        |> Enum.map(&box_to_latex/1)
        |> Enum.join("")

      true ->
        raw |> extract_string() |> to_latex_atom()
    end
  end

  # Strip the named wrapper and its closing `]` to get the inner content.
  defp box_strip(raw, prefix) do
    raw
    |> String.replace_prefix(prefix, "")
    |> then(fn s -> if String.ends_with?(s, "]"), do: String.slice(s, 0..-2//1), else: s end)
  end

  # Wrap in braces only when the LaTeX string is multi-character (for sub/superscripts).
  defp latex_brace(str) do
    if String.length(str) <= 1, do: str, else: "{#{str}}"
  end

  # Convert a plain-text atom to LaTeX, replacing unicode math symbols with
  # LaTeX commands so KaTeX can render them.
  defp to_latex_atom(str) do
    str
    |> String.replace("∑", "\\sum ")
    |> String.replace("∏", "\\prod ")
    |> String.replace("∫", "\\int ")
    |> String.replace("∞", "\\infty ")
    |> String.replace("∂", "\\partial ")
    |> String.replace("∇", "\\nabla ")
    |> String.replace("α", "\\alpha ")
    |> String.replace("β", "\\beta ")
    |> String.replace("γ", "\\gamma ")
    |> String.replace("δ", "\\delta ")
    |> String.replace("ε", "\\epsilon ")
    |> String.replace("ζ", "\\zeta ")
    |> String.replace("η", "\\eta ")
    |> String.replace("θ", "\\theta ")
    |> String.replace("λ", "\\lambda ")
    |> String.replace("μ", "\\mu ")
    |> String.replace("ν", "\\nu ")
    |> String.replace("ξ", "\\xi ")
    |> String.replace("π", "\\pi ")
    |> String.replace("ρ", "\\rho ")
    |> String.replace("σ", "\\sigma ")
    |> String.replace("τ", "\\tau ")
    |> String.replace("φ", "\\phi ")
    |> String.replace("χ", "\\chi ")
    |> String.replace("ψ", "\\psi ")
    |> String.replace("ω", "\\omega ")
    |> String.replace("Γ", "\\Gamma ")
    |> String.replace("Δ", "\\Delta ")
    |> String.replace("Θ", "\\Theta ")
    |> String.replace("Λ", "\\Lambda ")
    |> String.replace("Ξ", "\\Xi ")
    |> String.replace("Π", "\\Pi ")
    |> String.replace("Σ", "\\Sigma ")
    |> String.replace("Υ", "\\Upsilon ")
    |> String.replace("Φ", "\\Phi ")
    |> String.replace("Ψ", "\\Psi ")
    |> String.replace("Ω", "\\Omega ")
    |> String.replace("×", "\\times ")
    |> String.replace("÷", "\\div ")
    |> String.replace("±", "\\pm ")
    |> String.replace("≤", "\\leq ")
    |> String.replace("≥", "\\geq ")
    |> String.replace("≠", "\\neq ")
    |> String.replace("→", "\\to ")
    |> String.replace("←", "\\leftarrow ")
    |> String.replace("√", "\\sqrt")
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp extract_string(raw) do
    raw
    |> String.trim()
    |> then(fn s ->
      if String.starts_with?(s, "\"") and String.ends_with?(s, "\"") do
        s |> String.slice(1..-2//1) |> unescape_string()
      else
        unescape_string(s)
      end
    end)
  end

  defp unescape_string(str) do
    str
    # Strip Wolfram verbatim string markers \<\ ... \> (and optional surrounding newlines)
    |> String.replace(~r/^\\<\\?\r?\n?/, "")
    |> String.replace(~r/(\\?\r?\n)?\\>$/, "")
    # Line continuation: backslash immediately followed by a real newline
    |> String.replace("\\\n", " ")
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
    |> decode_wolfram_hex_escapes()
    |> replace_wolfram_named_chars()
    |> clean_wolfram_number_notation()
  end

  # Decode \:XXXX (4-hex unicode) and \.XX (2-hex byte) escapes.
  defp decode_wolfram_hex_escapes(str) do
    str
    |> then(fn s ->
      Regex.replace(~r/\\:([0-9a-fA-F]{4})/, s, fn _, hex ->
        cp = String.to_integer(hex, 16)
        # Drop zero-width / invisible formatting characters
        if cp in [0x200B, 0x200C, 0x200D, 0xFEFF], do: "", else: <<cp::utf8>>
      end)
    end)
    |> then(fn s ->
      Regex.replace(~r/\\.([0-9a-fA-F]{2})/, s, fn _, hex ->
        <<String.to_integer(hex, 16)::utf8>>
      end)
    end)
  end

  # Convert Wolfram machine-precision notation to readable form.
  # 1.23`*^13 → 1.23×10^13   |   trailing backtick precision marker stripped.
  defp clean_wolfram_number_notation(str) do
    str
    |> then(fn s ->
      Regex.replace(~r/`\*\^(-?\d+)/, s, fn _, exp -> "×10^#{exp}" end)
    end)
    |> then(fn s ->
      Regex.replace(~r/(\d)`/, s, fn _, d -> d end)
    end)
  end

  defp replace_wolfram_named_chars(str) do
    replacements = [
      {"\\[Alpha]", "α"},
      {"\\[Beta]", "β"},
      {"\\[Gamma]", "γ"},
      {"\\[Delta]", "δ"},
      {"\\[Epsilon]", "ε"},
      {"\\[Zeta]", "ζ"},
      {"\\[Eta]", "η"},
      {"\\[Theta]", "θ"},
      {"\\[Lambda]", "λ"},
      {"\\[Mu]", "μ"},
      {"\\[Nu]", "ν"},
      {"\\[Xi]", "ξ"},
      {"\\[Pi]", "π"},
      {"\\[Rho]", "ρ"},
      {"\\[Sigma]", "σ"},
      {"\\[Tau]", "τ"},
      {"\\[Phi]", "φ"},
      {"\\[Chi]", "χ"},
      {"\\[Psi]", "ψ"},
      {"\\[Omega]", "ω"},
      {"\\[Infinity]", "∞"},
      {"\\[LeftArrow]", "←"},
      {"\\[RightArrow]", "→"},
      {"\\[UpArrow]", "↑"},
      {"\\[DownArrow]", "↓"},
      {"\\[Equal]", "="},
      {"\\[NotEqual]", "≠"},
      {"\\[LessEqual]", "≤"},
      {"\\[GreaterEqual]", "≥"},
      {"\\[Times]", "×"},
      {"\\[Divide]", "÷"},
      {"\\[PlusMinus]", "±"},
      {"\\[Sum]", "∑"},
      {"\\[Product]", "∏"},
      {"\\[Integral]", "∫"},
      {"\\[SquareRoot]", "√"},
      {"\\[Degree]", "°"},
      {"\\[RawNewline]", "\n"},
      {"\\[IndentingNewLine]", "\n"},
      {"\\[NonBreakingSpace]", " "},
      {"\\[ThickSpace]", " "},
      {"\\[ThinSpace]", " "},
      {"\\[MediumSpace]", " "},
      {"\\[NegativeThickSpace]", ""},
      {"\\[NegativeThinSpace]", ""},
      {"\\[NegativeMediumSpace]", ""},
      {"\\[ZeroWidthSpace]", ""},
      {"\\[OAcute]", "Ó"},
      {"\\[AAcute]", "Á"},
      {"\\[EAcute]", "É"},
      {"\\[IAcute]", "Í"},
      {"\\[UAcute]", "Ú"},
      {"\\[ODoubleAcute]", "Ő"},
      {"\\[UDoubleAcute]", "Ű"},
      {"\\[AGrave]", "à"},
      {"\\[EGrave]", "è"},
      {"\\[IGrave]", "ì"},
      {"\\[OGrave]", "ò"},
      {"\\[UGrave]", "ù"},
      {"\\[ACircumflex]", "â"},
      {"\\[ECircumflex]", "ê"},
      {"\\[ICircumflex]", "î"},
      {"\\[OCircumflex]", "ô"},
      {"\\[UCircumflex]", "û"},
      {"\\[ATilde]", "ã"},
      {"\\[NTilde]", "ñ"},
      {"\\[OTilde]", "õ"},
      {"\\[AUmlaut]", "ä"},
      {"\\[EUmlaut]", "ë"},
      {"\\[IUmlaut]", "ï"},
      {"\\[OUmlaut]", "ö"},
      {"\\[UUmlaut]", "ü"},
      {"\\[Placeholder]", "▪"},
      {"\\[SelectionPlaceholder]", "▪"},
      {"\\[CloseCurlyQuote]", "'"},
      {"\\[OpenCurlyQuote]", "'"},
      {"\\[CloseCurlyDoubleQuote]", "\u201D"},
      {"\\[OpenCurlyDoubleQuote]", "\u201C"},
      {"\\[Dash]", "–"},
      {"\\[LongDash]", "—"},
      {"\\[Ellipsis]", "…"}
    ]

    Enum.reduce(replacements, str, fn {from, to}, acc ->
      String.replace(acc, from, to)
    end)
  end

  defp style_to_type(style) do
    case style do
      "Title" -> :title
      "Subtitle" -> :subtitle
      "Subsubtitle" -> :subsubtitle
      "Chapter" -> :chapter
      "Subchapter" -> :subchapter
      "Section" -> :section
      "Subsection" -> :subsection
      "Subsubsection" -> :subsubsection
      "Subsubsubsection" -> :subsubsubsection
      "Text" -> :text
      "Item" -> :item
      "Item1" -> :item
      "Item2" -> :item
      "ItemParagraph" -> :item_paragraph
      "Subitem" -> :subitem
      "Subitem1" -> :subitem
      "SubitemParagraph" -> :subitem_paragraph
      "Input" -> :code
      "Code" -> :code
      "Output" -> :output
      "Print" -> :print
      "Echo" -> :echo
      "Message" -> :message
      "InlineFormula" -> :inline_formula
      "DisplayFormula" -> :display_formula
      "DisplayFormulaNumbered" -> :display_formula
      "Program" -> :code
      "ExternalLanguage" -> :code
      "RawInputForm" -> :code
      "AbstractSection" -> :section
      "ReferenceSection" -> :section
      "Author" -> :author
      "Institution" -> :institution
      "Date" -> :date
      "Abstract" -> :abstract
      "TableText" -> :text
      "Table" -> :text
      "TableTitle" -> :subsection
      "Reference" -> :reference
      "FigureCaption" -> :figure_caption
      "FigureCaptionLine" -> :figure_caption
      "Caption" -> :figure_caption
      _ -> :unknown
    end
  end
end
