defmodule Tightbeam.Archetypes do
  @moduledoc """
  The archetype registry — identity as data (T4), minimal cut. An archetype
  is a declarative TOML manifest under `<base_dir>/identity/archetypes/
  <name>.toml`; this module loads them at boot, validates them, and compiles
  their guidance. This is deliberately NOT the full identity compiler (spec
  §Agent identity: guidance fragments, skills library, MCP, content-hash
  custom homes — the later milestone); it carries exactly the fields today's
  design needs and nothing else:

      name = "coder"
      where = ["eezo", "racter"]        # allowed host-set (§Placement).
                                        # Optional; default ["local"].

      [defaults]                        # optional spawn defaults
      harness = "codex"                 # "claude" | "codex"
      model   = "gpt-5.6-sol[medium]"

      [references]                      # optional — named pointers to work
                                        # materials; compile into guidance
                                        # TEXT, never substrate machinery
                                        # (point at the docs; copy the
                                        # identity; move the credentials
                                        # never).
      repo = { location = "eezo:~/src/tightbeam_ex", access = "git; gate: mix test" }

      [guidance]                        # optional extra guidance, appended
      text = \"\"\"...\"\"\"

  A built-in "default" archetype always exists (where ["local"], no
  references, no defaults) so a fresh install works with zero manifests. A
  manifest file named default.toml OVERRIDES the built-in.

  Loading is boot-time and whole-set: `load!/1` parses every manifest,
  validates (unknown top-level keys are ERRORS — a typo'd field must not
  silently become no-op law), and stores the set in `:persistent_term`
  (read-heavy, write-once-per-boot; identity changes re-load on restart —
  live reload is a later concern). A malformed manifest fails the boot: bad
  law should stop the factory, not limp.

  Guidance compilation produces the FULL instructions file content for a
  home: the archetype header, the standing dark-factory preamble, the
  scheduling-wakes skill (owned here, not by the Gateway), the references
  section rendered as "## Your materials" (name, location, access notes),
  then any manifest guidance text. Compilation is pure — same manifest, same
  bytes — because home projection is hash-gated on its output.
  """

  @persist_key __MODULE__

  @typedoc "A validated archetype."
  @type t :: %{
          name: String.t(),
          where: [String.t()],
          defaults: %{optional(:harness) => :claude | :codex, optional(:model) => String.t()},
          references: [%{name: String.t(), location: String.t(), access: String.t() | nil}],
          guidance: String.t() | nil
        }

  @scheduling_wakes_skill """
  Use the `tightbeam` CLI to coordinate with other sessions. Run
  `tightbeam help` any time for full, authoritative usage of every command and
  flag. Your identity for every call is your own handle, passed with
  `--as <handle>` (this is WHO the call is from, not the target).

  - DM another session now (delivers a prompt it will act on):
      tightbeam wake <sessionKeyOrHandle> --prompt "..." --as <your-handle>
  - Schedule a follow-up for yourself or another session later:
      tightbeam wake <target> --prompt "..." --after 5m --as <your-handle>
      (durations: 30s, 5m, 2h)
  - Hire a worker session:
      tightbeam spawn --display "Reviewer" --name reviewer:x --harness codex \\
        --model "gpt-5.6-sol[high]" --as <your-handle>
  - See the org you can address:
      tightbeam list --as <your-handle>
  - Cancel a pending wake:
      tightbeam cancel-wake <wakeId> --as <your-handle>

  A wake always carries a prompt — there is no content-free ping. A wake is not
  an obligation to reply; act only if you have something to add.
  """

  @doc """
  Load every manifest under `<base_dir>/identity/archetypes/*.toml`, validate,
  merge over the built-in default, and store the set in :persistent_term.
  Raises (failing boot) on: unparseable TOML, unknown top-level keys, `where`
  not a non-empty list of strings, defaults.harness outside claude|codex, a
  reference missing `location`. Returns the loaded map (name => t()).
  """
  @spec load!(String.t()) :: %{optional(String.t()) => t()}
  def load!(base_dir) do
    manifest_dir = Path.join([base_dir, "identity", "archetypes"])

    archetypes =
      manifest_dir
      |> Path.join("*.toml")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reduce(%{"default" => builtin_default()}, fn path, loaded ->
        manifest = path |> File.read!() |> Toml.decode!()
        archetype = validate!(manifest, path)
        Map.put(loaded, archetype.name, archetype)
      end)

    :persistent_term.put(@persist_key, archetypes)
    archetypes
  end

  @doc "The loaded archetype by name, or nil. Reads :persistent_term (load!/1 must have run)."
  @spec get(String.t()) :: t() | nil
  def get(name) do
    Map.get(:persistent_term.get(@persist_key), name)
  end

  @doc "All loaded archetype names."
  @spec names() :: [String.t()]
  def names do
    @persist_key
    |> :persistent_term.get()
    |> Map.keys()
    |> Enum.sort()
  end

  @doc """
  Compile the full instructions-file content for an archetype (see moduledoc
  for the section order). Pure: identical manifest → identical bytes.
  """
  @spec guidance(t()) :: String.t()
  def guidance(archetype) do
    preamble =
      [
        "# Tightbeam · #{archetype.name}",
        "",
        "You are an agent in a Tightbeam dark factory. You can talk to other",
        "sessions and schedule your own follow-ups with the `tightbeam` CLI.",
        "See the scheduling-wakes skill below.",
        "",
        "## Skill: scheduling-wakes",
        @scheduling_wakes_skill
      ]
      |> Enum.join("\n")

    materials =
      case archetype.references do
        [] ->
          nil

        references ->
          lines =
            Enum.flat_map(references, fn reference ->
              ["- #{reference.name}: #{reference.location}"] ++
                if(reference.access, do: ["  access: #{reference.access}"], else: [])
            end)

          Enum.join(["## Your materials" | lines], "\n")
      end

    with_materials = if materials, do: preamble <> "\n" <> materials, else: preamble

    if archetype.guidance do
      separator = if materials, do: "\n\n", else: "\n"
      with_materials <> separator <> archetype.guidance
    else
      with_materials
    end
  end

  @doc "The built-in default archetype (used when no manifest overrides it)."
  @spec builtin_default() :: t()
  def builtin_default do
    %{name: "default", where: ["local"], defaults: %{}, references: [], guidance: nil}
  end

  defp validate!(manifest, path) do
    allowed = MapSet.new(["name", "where", "defaults", "references", "guidance"])

    unknown =
      manifest |> Map.keys() |> MapSet.new() |> MapSet.difference(allowed) |> MapSet.to_list()

    if unknown != [] do
      raise ArgumentError,
            "unknown top-level archetype keys in #{path}: #{unknown |> Enum.sort() |> Enum.join(", ")}"
    end

    name = Map.get(manifest, "name", Path.basename(path, ".toml"))
    where = Map.get(manifest, "where", ["local"])

    unless is_list(where) and where != [] and Enum.all?(where, &is_binary/1) do
      raise ArgumentError, "archetype where must be a non-empty list of strings: #{path}"
    end

    raw_defaults = Map.get(manifest, "defaults", %{})
    harness = raw_defaults["harness"]

    if harness not in [nil, "claude", "codex"] do
      raise ArgumentError, "archetype defaults.harness must be claude or codex: #{path}"
    end

    defaults =
      %{}
      |> maybe_put(:harness, harness && String.to_existing_atom(harness))
      |> maybe_put(:model, raw_defaults["model"])

    references =
      manifest
      |> Map.get("references", %{})
      |> Enum.sort_by(fn {reference_name, _reference} -> reference_name end)
      |> Enum.map(fn {reference_name, reference} ->
        location = reference["location"]

        unless is_binary(location) do
          raise ArgumentError,
                "archetype reference #{reference_name} is missing location: #{path}"
        end

        %{name: reference_name, location: location, access: reference["access"]}
      end)

    %{
      name: name,
      where: where,
      defaults: defaults,
      references: references,
      guidance: get_in(manifest, ["guidance", "text"])
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
