defmodule Tightbeam.Homes do
  @moduledoc """
  Projects disposable harness homes from archetype guidance and extra files
  (TS reference: `src/homes/project.ts`). Credentials remain owned by
  `<base_dir>/auth/<harness>` and are only symlinked into generated homes;
  regeneration never writes to or deletes the auth source.
  """

  @typedoc "A structured harness-home projection input."
  @type spec :: %{
          required(:harness) => :claude | :codex,
          required(:archetype) => String.t(),
          required(:guidance) => String.t(),
          optional(:extra_files) => %{optional(String.t()) => String.t()}
        }

  @typedoc "The generated home paths and auth entries linked into it."
  @type projected_home :: %{
          home_path: String.t(),
          instructions_file: String.t(),
          linked_auth_files: [String.t()]
        }

  @doc """
  Regenerates one home from its spec, writes the harness instruction file and
  extra files, then symlinks every harness auth entry into the home root. The
  generated home is disposable; the auth source is never modified.
  """
  @spec project(String.t(), spec()) :: projected_home()
  def project(base_dir, spec) do
    harness = spec.harness
    home_path = Path.join([base_dir, "homes", spec.archetype, Atom.to_string(harness)])
    auth_dir = Path.join([base_dir, "auth", Atom.to_string(harness)])

    File.rm_rf!(home_path)
    File.mkdir_p!(home_path)

    instructions_file = if harness == :claude, do: "CLAUDE.md", else: "AGENTS.md"
    instructions_path = Path.join(home_path, instructions_file)
    File.write!(instructions_path, spec.guidance)

    for {relative_path, content} <- Map.get(spec, :extra_files, %{}) do
      absolute_path = Path.join(home_path, relative_path)
      File.mkdir_p!(Path.dirname(absolute_path))
      File.write!(absolute_path, content)
    end

    linked_auth_files =
      case File.ls(auth_dir) do
        {:ok, files} ->
          for file <- files do
            File.ln_s!(Path.join(auth_dir, file), Path.join(home_path, file))
            file
          end

        {:error, :enoent} ->
          []
      end

    %{
      home_path: home_path,
      instructions_file: instructions_path,
      linked_auth_files: linked_auth_files
    }
  end
end
