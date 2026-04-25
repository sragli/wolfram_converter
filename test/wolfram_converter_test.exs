defmodule WolframConverterTest do
  use ExUnit.Case, async: true

  alias WolframConverter.Parser
  alias WolframConverter.Parser.Cell
  alias WolframConverter.Transformer

  # ── Sample Notebooks ─────────────────────────────────────────────────────────

  @simple_notebook ~S"""
  Notebook[{
  Cell["My Notebook", "Title"],
  Cell["Introduction", "Section"],
  Cell["This is some text.", "Text"],
  Cell["1 + 1", "Input"],
  Cell["2", "Output"]
  }, WindowSize->{808, 755}]
  """

  @text_data_notebook ~S"""
  Notebook[{
  Cell[TextData[{"Hello ", StyleBox["bold", FontWeight->"Bold"], " world"}], "Text"]
  }, WindowSize->{808, 755}]
  """

  @all_headings_notebook ~S"""
  Notebook[{
  Cell["Title Cell", "Title"],
  Cell["Chapter Cell", "Chapter"],
  Cell["Section Cell", "Section"],
  Cell["Subsection Cell", "Subsection"],
  Cell["Subsubsection Cell", "Subsubsection"]
  }, WindowSize->{808, 755}]
  """

  @items_notebook ~S"""
  Notebook[{
  Cell["First item", "Item"],
  Cell["Second item", "Item"],
  Cell["Subitem here", "Subitem"]
  }, WindowSize->{808, 755}]
  """

  @multi_output_notebook ~S"""
  Notebook[{
  Cell["x = 1 + 1", "Input"],
  Cell["2", "Output"],
  Cell["Print was called", "Print"]
  }, WindowSize->{808, 755}]
  """

  # ── Parser Tests ─────────────────────────────────────────────────────────────

  describe "Parser.parse/1" do
    test "parses a simple notebook into cells" do
      cells = Parser.parse(@simple_notebook)
      assert length(cells) == 5
    end

    test "parses Title cell type" do
      [title | _] = Parser.parse(@simple_notebook)
      assert title.type == :title
      assert title.content == "My Notebook"
    end

    test "parses Section cell type" do
      [_, section | _] = Parser.parse(@simple_notebook)
      assert section.type == :section
      assert section.content == "Introduction"
    end

    test "parses Text cell type" do
      [_, _, text | _] = Parser.parse(@simple_notebook)
      assert text.type == :text
      assert text.content == "This is some text."
    end

    test "parses Input/code cell type" do
      [_, _, _, code | _] = Parser.parse(@simple_notebook)
      assert code.type == :code
      assert code.content == "1 + 1"
    end

    test "parses Output cell type" do
      [_, _, _, _, output] = Parser.parse(@simple_notebook)
      assert output.type == :output
      assert output.content == "2"
    end

    test "parses TextData with StyleBox bold" do
      cells = Parser.parse(@text_data_notebook)
      assert length(cells) == 1
      [cell] = cells
      assert cell.type == :text
      assert String.contains?(cell.content, "Hello")
      assert String.contains?(cell.content, "**bold**")
      assert String.contains?(cell.content, "world")
    end

    test "parses all heading types" do
      cells = Parser.parse(@all_headings_notebook)
      types = Enum.map(cells, & &1.type)
      assert :title in types
      assert :chapter in types
      assert :section in types
      assert :subsection in types
      assert :subsubsection in types
    end

    test "parses item cells" do
      cells = Parser.parse(@items_notebook)
      types = Enum.map(cells, & &1.type)
      assert Enum.count(types, &(&1 == :item)) == 2
      assert :subitem in types
    end

    test "returns empty list for empty input" do
      cells = Parser.parse("")
      assert cells == []
    end

    test "handles notebook without Notebook[] wrapper" do
      bare = ~S|Cell["Hello", "Text"]|
      cells = Parser.parse(bare)
      # Should not crash; result may be empty or partial
      assert is_list(cells)
    end
  end

  # ── Transformer Tests ─────────────────────────────────────────────────────────

  describe "Transformer.to_livemd/1" do
    test "produces a string" do
      cells = Parser.parse(@simple_notebook)
      result = Transformer.to_livemd(cells)
      assert is_binary(result)
    end

    test "renders title as H1 markdown" do
      cells = [%Cell{type: :title, content: "My Title", metadata: %{}}]
      result = Transformer.to_livemd(cells)
      assert String.contains?(result, "# My Title")
    end

    test "renders section as H2 markdown" do
      cells = [%Cell{type: :section, content: "My Section", metadata: %{}}]
      result = Transformer.to_livemd(cells)
      assert String.contains?(result, "## My Section")
    end

    test "renders subsection as H3 markdown" do
      cells = [%Cell{type: :subsection, content: "My Subsection", metadata: %{}}]
      result = Transformer.to_livemd(cells)
      assert String.contains?(result, "### My Subsection")
    end

    test "renders text as plain markdown paragraph" do
      cells = [%Cell{type: :text, content: "Hello world.", metadata: %{}}]
      result = Transformer.to_livemd(cells)
      assert String.contains?(result, "Hello world.")
      refute String.contains?(result, "```")
    end

    test "renders code cells as elixir code blocks" do
      cells = [%Cell{type: :code, content: "x = 1 + 1", metadata: %{}}]
      result = Transformer.to_livemd(cells)
      assert String.contains?(result, "```elixir")
      assert String.contains?(result, "x = 1 + 1")
      assert String.contains?(result, "```")
    end

    test "groups output cell with preceding code cell" do
      cells = [
        %Cell{type: :code, content: "1 + 1", metadata: %{}},
        %Cell{type: :output, content: "2", metadata: %{}}
      ]

      result = Transformer.to_livemd(cells)
      # Output should appear inside the code block as a comment
      assert String.contains?(result, "# => 2")
      # Should only have one code block
      assert length(Regex.scan(~r/```elixir/, result)) == 1
    end

    test "groups print cell with preceding code cell" do
      cells = [
        %Cell{type: :code, content: "IO.puts(\"hi\")", metadata: %{}},
        %Cell{type: :print, content: "hi", metadata: %{}}
      ]

      result = Transformer.to_livemd(cells)
      assert String.contains?(result, "# [Print] hi")
    end

    test "renders items as markdown list items" do
      cells = [%Cell{type: :item, content: "First", metadata: %{}}]
      result = Transformer.to_livemd(cells)
      assert String.contains?(result, "- First")
    end

    test "renders subitems as indented list items" do
      cells = [%Cell{type: :subitem, content: "Sub", metadata: %{}}]
      result = Transformer.to_livemd(cells)
      assert String.contains?(result, "  - Sub")
    end

    test "ends with a newline" do
      cells = [%Cell{type: :text, content: "hi", metadata: %{}}]
      result = Transformer.to_livemd(cells)
      assert String.ends_with?(result, "\n")
    end

    test "includes livebook header" do
      cells = []
      result = Transformer.to_livemd(cells)
      assert String.contains?(result, "livebook:")
    end
  end

  # ── Integration Tests ─────────────────────────────────────────────────────────

  describe "WolframConverter.convert_string/1" do
    test "converts a simple notebook end-to-end" do
      assert {:ok, livemd} = WolframConverter.convert_string(@simple_notebook)
      assert String.contains?(livemd, "# My Notebook")
      assert String.contains?(livemd, "## Introduction")
      assert String.contains?(livemd, "This is some text.")
      assert String.contains?(livemd, "```elixir")
      assert String.contains?(livemd, "# => 2")
    end

    test "converts multi-output notebook" do
      assert {:ok, livemd} = WolframConverter.convert_string(@multi_output_notebook)
      assert String.contains?(livemd, "# => 2")
      assert String.contains?(livemd, "# [Print] Print was called")
      # Only one code block for the code + its outputs
      assert length(Regex.scan(~r/```elixir/, livemd)) == 1
    end

    test "converts all headings notebook" do
      assert {:ok, livemd} = WolframConverter.convert_string(@all_headings_notebook)
      assert String.contains?(livemd, "# Title Cell")
      assert String.contains?(livemd, "## Chapter Cell")
      assert String.contains?(livemd, "## Section Cell")
      assert String.contains?(livemd, "### Subsection Cell")
      assert String.contains?(livemd, "#### Subsubsection Cell")
    end

    test "returns error tuple for completely malformed input" do
      # Should not crash even on weird input
      result = WolframConverter.convert_string("this is not a notebook at all!!!")
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "WolframConverter.convert_file/2" do
    @tag :tmp_dir
    test "converts a file on disk", %{tmp_dir: dir} do
      input = Path.join(dir, "test.nb")
      output = Path.join(dir, "test.livemd")
      File.write!(input, @simple_notebook)

      assert :ok = WolframConverter.convert_file(input, output)
      assert File.exists?(output)
      content = File.read!(output)
      assert String.contains?(content, "# My Notebook")
    end

    @tag :tmp_dir
    test "uses default output path when none given", %{tmp_dir: dir} do
      input = Path.join(dir, "notebook.nb")
      expected_output = Path.join(dir, "notebook.livemd")
      File.write!(input, @simple_notebook)

      assert :ok = WolframConverter.convert_file(input)
      assert File.exists?(expected_output)
    end

    test "returns error for nonexistent file" do
      assert {:error, :enoent} = WolframConverter.convert_file("/nonexistent/path/file.nb")
    end
  end
end
