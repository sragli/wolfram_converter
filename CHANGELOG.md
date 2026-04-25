# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-04-25

### Added

- Parser for Wolfram Notebook (`.nb`) files: `Notebook[{cells...}]`, `Cell[content, "Style", opts]`, `TextData`, `BoxData`, and all common box types
- `CellGroupData` blocks recursively unwrapped at any depth
- Cell type mapping: Title, Chapter, Section, Subsection, Subsubsection, Text, Input/Code, Output, Print/Echo, Item/Subitem, InlineFormula, DisplayFormula, Author, Institution, Date, Abstract, FigureCaption, Reference
- Math rendering — box expressions (`FractionBox`, `SuperscriptBox`, `SubscriptBox`, `SqrtBox`, `UnderoverscriptBox`, `RowBox`, …) converted to `$LaTeX$` / `$$LaTeX$$`
- `GridBox` → Markdown table; `GraphicsBox`/`RasterBox` → `[figure]` placeholder
- Styled text: bold/italic via `StyleBox`; `CounterBox` stripped from headings
- Output/Print/Echo cells grouped as `# => ...` comments inside the preceding code cell
- Character decoding: `\:XXXX` hex escapes, `\.XX` byte escapes, Wolfram machine-precision numbers (`1.23\`*^9` → `1.23×10^9`), verbatim string delimiters, 60+ named character mappings
- CLI (`WolframConverter.CLI`), standalone script (`wolfram_converter.exs`), and escript build target
- 30 ExUnit tests

### Fixed

- Infinite loop when `extract_box_content/1` encountered raw list or compressed-data content
- O(n²) list appends replaced with prepend + reverse throughout the parser
- Catastrophic regex backtracking on large files replaced with O(n) binary scanner
- `String.graphemes/1` allocations replaced with binary pattern matching for performance

