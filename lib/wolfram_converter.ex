defmodule WolframConverter do
  @moduledoc """
  Converts Wolfram Mathematica Notebook (.nb) files to Elixir Livebook (.livemd) format.

  Wolfram Notebooks are structured as nested Mathematica expressions. This converter
  parses the cell structure and maps each cell type to the appropriate Livebook equivalent.

  ## Supported Wolfram Cell Types

  | Wolfram Cell Type | Livebook Equivalent         |
  |-------------------|-----------------------------|
  | Title             | `# Title` (H1 Markdown)     |
  | Chapter           | `## Chapter` (H2 Markdown)  |
  | Section           | `### Section` (H3 Markdown) |
  | Subsection        | `#### Subsection` (H4)      |
  | Subsubsection     | `##### Subsubsection` (H5)  |
  | Text              | Markdown paragraph          |
  | Code / Input      | Elixir code cell            |
  | Output            | Comment block in code cell  |
  | Print / Echo      | Comment block in code cell  |
  | Item              | Markdown list item          |

  ## Usage

      # Convert a file
      WolframToLivebook.convert_file("notebook.nb", "notebook.livemd")

      # Convert from string
      {:ok, livemd} = WolframToLivebook.convert_string(notebook_content)
  """

  alias WolframConverter.{Parser, Transformer}

  @doc """
  Converts a Wolfram Notebook file to Livebook format and writes the result.

  ## Parameters

    - `input_path`  – path to the `.nb` file
    - `output_path` – path to write the `.livemd` file (defaults to input path with `.livemd` extension)

  ## Returns

    - `:ok` on success
    - `{:error, reason}` on failure
  """
  @spec convert_file(String.t(), String.t() | nil) :: :ok | {:error, term()}
  def convert_file(input_path, output_path \\ nil) do
    output_path = output_path || Path.rootname(input_path) <> ".livemd"

    with {:ok, content} <- File.read(input_path),
         {:ok, livemd} <- convert_string(content) do
      File.write(output_path, livemd)
    end
  end

  @doc """
  Converts Wolfram Notebook content (as a string) to Livebook Markdown.

  ## Returns

    - `{:ok, livemd_string}` on success
    - `{:error, reason}` on failure
  """
  @spec convert_string(String.t()) :: {:ok, String.t()} | {:error, term()}
  def convert_string(content) do
    try do
      cells = Parser.parse(content)
      livemd = Transformer.to_livemd(cells)
      {:ok, livemd}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
end
