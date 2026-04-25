# WolframConverter

Converts Wolfram Mathematica Notebook (`.nb`) files to [Elixir Livebook](https://livebook.dev/) (`.livemd`) format.

The converter parses the nested Mathematica expression structure of `.nb` files, maps each cell type to its Livebook/Markdown equivalent, converts box-based math expressions to LaTeX (rendered by Livebook via KaTeX), and handles the full range of inline formatting, styled text, tables, and figures.

## Features

- **Cell types** — Title, Chapter, Section, Subsection, Subsubsection, Text, Input/Code, Output, Print/Echo, Item/Subitem, DisplayFormula, InlineFormula, Author, Abstract, FigureCaption, Reference, and more
- **Math rendering** — Box expressions (`FractionBox`, `SuperscriptBox`, `SubscriptBox`, `SqrtBox`, `UnderoverscriptBox`, `RowBox`, …) are converted to `$LaTeX$` / `$$LaTeX$$`
- **Tables** — `GridBox` → Markdown table with header separator
- **Styled text** — `StyleBox` bold/italic → `**bold**` / `_italic_`; `TextData` mixed-format paragraphs
- **Wolfram escapes** — `\:XXXX` hex unicode, `\.XX` byte escapes, `\[NamedChar]`, verbatim strings (`\<\...\>`), line-continuation backslashes, machine-precision numbers (`1.23\`*^9` → `1.23×10^9`)
- **Nested structure** — `CellGroupData` groups unwrapped recursively
- **Figures** — graphic cells (`GraphicsBox`, `RasterBox`) rendered as `[figure]` placeholder
- **Performance** — O(n) binary-pattern-matching parser; handles large notebooks (>1 MB) in under 2 seconds

## Usage

### As a Mix dependency

```elixir
def deps do
  [
    {:wolfram_converter, "~> 0.1.0"}
  ]
end
```

```elixir
# Convert a file (output defaults to same path with .livemd extension)
:ok = WolframConverter.convert_file("notebook.nb")
:ok = WolframConverter.convert_file("notebook.nb", "output.livemd")

# Convert from a string
{:ok, livemd} = WolframConverter.convert_string(nb_content)
```

### As a standalone script

```bash
elixir wolfram_converter.exs input.nb [output.livemd]
```

### As a compiled escript

```bash
mix escript.build
./wolfram_converter input.nb [output.livemd]
./wolfram_converter --help
```

## Cell type mapping

| Wolfram style | Livebook equivalent |
|---|---|
| `Title` | `# H1` |
| `Chapter` / `Section` | `## H2` |
| `Subsection` / `AbstractSection` | `### H3` |
| `Subsubsection` | `#### H4` |
| `Subsubsubsection` | `##### H5` |
| `Text` | Markdown paragraph |
| `Input` / `Code` / `Program` | ` ```elixir ``` ` code cell |
| `Output` | `# => ...` comment in preceding code cell |
| `Print` / `Echo` | `# [Print] ...` comment in preceding code cell |
| `Item` / `Item1` / `Item2` | `- list item` |
| `Subitem` | `  - nested list item` |
| `InlineFormula` | `$LaTeX$` inline math |
| `DisplayFormula` | `$$LaTeX$$` display math |
| `TableTitle` | `### heading` above table |
| `FigureCaption` | _italic caption_ |
| `Author` / `Institution` / `Date` | _italic metadata_ |
| `Reference` | `- reference` list item |

## Development

```bash
mix deps.get
mix test
mix docs        # generate ExDoc documentation
```
