defmodule Tightbeam.Archetypes do
  @moduledoc """
  Loads and validates archetype manifests from one immutable served-identity
  revision. Manifests elect shared skill bodies by name, constrain placement,
  define defaults and MCP servers, and compose auditable guidance fragments.

  `Tightbeam.Identity` owns the three-ref repository and is the one final
  composer. It reads the archetype, elected skills, and operating-model
  fragment through one revision, then renders the harness-accurate session
  instructions. No archetype identity is projected into a harness home.
  """

  @persist_key __MODULE__
  @shipped_output_kinds %{
    "default" => :coordination,
    "orchestrator" => :coordination,
    "coder" => :artifact,
    "product-owner" => :artifact,
    "spec-writer" => :artifact,
    "reviewer" => :verdict,
    "recon" => :verdict
  }
  alias Tightbeam.Identity.Renderer

  @typedoc "A validated archetype."
  @type t :: %{
          name: String.t(),
          output_kind: :coordination | :artifact | :verdict,
          skills: [String.t()],
          where: [String.t()],
          defaults: %{optional(:harness) => atom(), optional(:model) => Tightbeam.Model.t()},
          references: [%{name: String.t(), location: String.t(), access: String.t() | nil}],
          model_preferences: [Tightbeam.Model.t()],
          containment: %{fs: :off, network: :open},
          mcp: [
            %{
              name: String.t(),
              command: String.t(),
              args: [String.t()],
              env: %{optional(String.t()) => String.t()}
            }
          ],
          guidance: String.t() | nil,
          source: %{file: String.t(), sha256: String.t()} | nil
        }

  @doc """
  Load every manifest under `<base_dir>/identity/archetypes/*.toml`, validate,
  merge over the built-in default, and store the set in :persistent_term.
  Raises (failing boot) on: unparseable TOML, unknown top-level keys, `where`
  not a non-empty list of strings, defaults.harness outside claude|codex, a
  reference missing `location`, or an org skill using a reserved substrate
  name. Returns the loaded map (name => t()).
  """
  @spec load!(String.t()) :: %{optional(String.t()) => t()}
  def load!(base_dir) do
    manifest_dir = Path.join([base_dir, "identity", "archetypes"])

    refuse_reserved_substrate_skills!(base_dir)

    library =
      base_dir
      |> skills_dir()
      |> Path.join("*/SKILL.md")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
      |> MapSet.new()
      |> MapSet.union(MapSet.new(Tightbeam.Homes.baseline_skill_names()))

    archetypes =
      manifest_dir
      |> Path.join("*.toml")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reduce(%{"default" => builtin_default()}, fn path, loaded ->
        bytes = File.read!(path)
        manifest = Toml.decode!(bytes)

        archetype =
          manifest
          |> validate!(path)
          |> Map.put(:source, %{
            file: Path.relative_to(path, base_dir),
            sha256: bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
          })

        Map.put(loaded, archetype.name, archetype)
      end)

    fragments = load_fragments!(base_dir)

    # Validate ALL law at load: every archetype's guidance must compose
    # (missing fragments and include cycles fail the boot, not a turn), and
    # every elected skill must exist in the library.
    for {_name, archetype} <- archetypes do
      guidance_with(archetype, fragments)

      case Enum.reject(archetype.skills, &MapSet.member?(library, &1)) do
        [] ->
          :ok

        unknown ->
          raise ArgumentError,
                "archetype #{archetype.name} elects unknown skills: #{Enum.join(unknown, ", ")}"
      end
    end

    :persistent_term.put(@persist_key, {archetypes, fragments})
    archetypes
  end

  defp refuse_reserved_substrate_skills!(base_dir) do
    for name <- Tightbeam.Homes.baseline_skill_names() do
      path = Path.join([skills_dir(base_dir), name, "SKILL.md"])

      if File.regular?(path) do
        raise ArgumentError,
              "#{path}: rename or remove the org copy; substrate names are reserved"
      end
    end
  end

  @doc """
  The loaded fragment library. Org identity files override elected bundle guidance;
  the substrate operating manual remains built-in and immutable.
  """
  @spec fragments() :: %{optional(String.t()) => String.t()}
  def fragments do
    # Before load!/1 has run (unit tests, tooling) the built-ins stand alone.
    {_archetypes, fragments} = :persistent_term.get(@persist_key, {%{}, builtin_fragments()})
    fragments
  end

  @doc "The loaded archetype by name, or nil. Reads :persistent_term (load!/1 must have run)."
  @spec get(String.t()) :: t() | nil
  def get(name) do
    {archetypes, _fragments} = :persistent_term.get(@persist_key)
    Map.get(archetypes, name)
  end

  @doc "Return an archetype's completion output contract, failing safe to artifact."
  @spec output_kind(String.t()) :: :coordination | :artifact | :verdict
  def output_kind(name) do
    {archetypes, _fragments} = :persistent_term.get(@persist_key, {%{}, builtin_fragments()})

    case Map.get(archetypes, name) do
      %{output_kind: kind} when kind in [:coordination, :artifact, :verdict] -> kind
      _ -> Map.get(@shipped_output_kinds, name, :artifact)
    end
  end

  @doc "Compile an archetype's MCP declarations to the ACP mcpServers shape."
  @spec acp_mcp_servers(t()) :: [map()]
  def acp_mcp_servers(archetype) do
    Enum.map(archetype.mcp, fn server ->
      %{
        "name" => server.name,
        "command" => server.command,
        "args" => server.args,
        "env" =>
          server.env
          |> Enum.sort_by(fn {name, _value} -> name end)
          |> Enum.map(fn {name, value} -> %{"name" => name, "value" => value} end)
      }
    end)
  end

  @doc "Parse and validate one archetype manifest without mutating the loaded registry."
  @spec parse_manifest!(binary(), String.t()) :: t()
  def parse_manifest!(bytes, path) do
    bytes
    |> Toml.decode!()
    |> validate!(path)
    |> Map.put(:source, %{
      file: path,
      sha256: bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
    })
  end

  @doc "Compose guidance against an explicit immutable fragment set."
  @spec guidance(t(), %{optional(String.t()) => String.t()}) :: String.t()
  def guidance(archetype, fragments), do: guidance_with(archetype, fragments)

  @doc "Resolve includes against an explicit immutable fragment set."
  @spec resolve_guidance!(String.t(), %{optional(String.t()) => String.t()}) :: String.t()
  def resolve_guidance!(text, fragments) do
    Renderer.render!(text, "archetype-guidance", fragments).bytes
  end

  @doc "Compose one archetype while retaining include-graph metadata."
  @spec guidance_render(t(), map()) :: map()
  def guidance_render(archetype, fragments) do
    preamble = "# Tightbeam · #{archetype.name}"

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

    with_materials = if materials, do: preamble <> "\n\n" <> materials, else: preamble

    rendered =
      if archetype.guidance do
        origin = (archetype.source && archetype.source.file) || "archetype:#{archetype.name}"
        Renderer.render!(archetype.guidance, origin, fragments)
      else
        %{bytes: "", provenance: [], reachable_roots: MapSet.new(), root_occurrences: %{}}
      end

    bytes =
      if rendered.bytes == "",
        do: with_materials,
        else: with_materials <> "\n\n" <> rendered.bytes

    %{rendered | bytes: bytes}
  end

  @doc "Validate and normalize spawn-time session overrides."
  @spec normalize_overrides(String.t(), t(), term()) ::
          {:ok, map() | nil} | {:error, %{code: String.t(), message: String.t()}}
  def normalize_overrides(base_dir, archetype, raw) do
    with :ok <- override_object(raw),
         {:ok, values} <- override_keys(raw),
         {:ok, skills} <- override_skills(base_dir, archetype, values),
         {:ok, guidance} <- override_guidance(values) do
      normalized =
        %{}
        |> maybe_put_override("skills_add", skills)
        |> maybe_put_override("guidance_extra", guidance)

      {:ok, if(map_size(normalized) == 0, do: nil, else: normalized)}
    end
  end

  @doc "Compose a base archetype with normalized session overrides."
  @spec effective(t(), map() | nil, keyword()) :: t()
  def effective(archetype, overrides, opts \\ [])
  def effective(archetype, nil, _opts), do: archetype

  def effective(archetype, overrides, opts) do
    identity_name = Keyword.get(opts, :identity_name)
    base_dir = Keyword.get(opts, :base_dir)

    {added_skills, skill_discrepancies} =
      overrides
      |> Map.get("skills_add", [])
      |> Enum.reduce({[], []}, fn name, {present, discrepancies} ->
        if is_nil(base_dir) or skill_available?(base_dir, identity_name, name) do
          {[name | present], discrepancies}
        else
          {present, ["missing override skill #{name}" | discrepancies]}
        end
      end)

    {extra, guidance_discrepancies} =
      overrides
      |> Map.get("guidance_extra")
      |> resolve_override_guidance_lenient(fragments())

    discrepancies = Enum.reverse(skill_discrepancies) ++ guidance_discrepancies
    record_override_discrepancies(opts, discrepancies)

    composed =
      case extra do
        nil -> guidance(archetype)
        "" -> guidance(archetype)
        text -> guidance(archetype) <> "\n\n" <> text
      end

    archetype
    |> Map.put(:skills, Enum.sort(Enum.uniq(archetype.skills ++ added_skills)))
    |> Map.put(:override_skills, Enum.sort(added_skills))
    |> Map.put(:composed_guidance, composed)
  end

  @doc "The loaded archetype map (name => archetype)."
  @spec all() :: %{optional(String.t()) => t()}
  def all do
    {archetypes, _fragments} = :persistent_term.get(@persist_key)
    archetypes
  end

  @doc "All loaded archetype names."
  @spec names() :: [String.t()]
  def names do
    {archetypes, _fragments} = :persistent_term.get(@persist_key)
    archetypes |> Map.keys() |> Enum.sort()
  end

  @doc """
  Compile the full instructions-file content for an archetype (see moduledoc
  for the section order). Pure: identical manifest → identical bytes.
  """
  @spec guidance(t()) :: String.t()
  def guidance(%{composed_guidance: guidance}), do: guidance
  def guidance(archetype), do: guidance_with(archetype, fragments())

  defp guidance_with(archetype, fragments) do
    guidance_render(archetype, fragments).bytes
  end

  defp override_object(raw) when is_map(raw), do: :ok

  defp override_object(_raw),
    do: {:error, %{code: "invalid_overrides", message: "overrides must be an object"}}

  defp override_keys(raw) do
    values =
      Map.new(raw, fn {key, value} ->
        normalized_key = if is_atom(key), do: Atom.to_string(key), else: key
        {normalized_key, value}
      end)

    unknown = Map.keys(values) -- ["skills_add", "guidance_extra"]

    if unknown == [] do
      {:ok, values}
    else
      {:error,
       %{
         code: "invalid_overrides",
         message:
           "unknown override keys: #{unknown |> Enum.map(&inspect/1) |> Enum.sort() |> Enum.join(", ")}"
       }}
    end
  end

  defp override_skills(base_dir, archetype, values) do
    case Map.get(values, "skills_add", []) do
      skills when is_list(skills) ->
        if Enum.all?(skills, &is_binary/1) do
          roots =
            skills_dir(base_dir)
            |> Path.join("*/SKILL.md")
            |> Path.wildcard()
            |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
            |> MapSet.new()
            |> MapSet.union(MapSet.new(Tightbeam.Homes.baseline_skill_names()))

          unknown =
            skills |> Enum.uniq() |> Enum.reject(&MapSet.member?(roots, &1)) |> Enum.sort()

          if unknown == [] do
            normalized =
              skills
              |> Enum.uniq()
              |> Enum.reject(
                &(&1 in archetype.skills or &1 in Tightbeam.Homes.baseline_skill_names())
              )
              |> Enum.sort()

            {:ok, normalized}
          else
            {:error,
             %{
               code: "invalid_overrides",
               message: "unknown override skill names: #{Enum.join(unknown, ", ")}"
             }}
          end
        else
          {:error,
           %{code: "invalid_overrides", message: "overrides.skills_add must be a list of strings"}}
        end

      _ ->
        {:error,
         %{code: "invalid_overrides", message: "overrides.skills_add must be a list of strings"}}
    end
  end

  defp override_guidance(values) do
    case Map.fetch(values, "guidance_extra") do
      :error ->
        {:ok, nil}

      {:ok, guidance} when is_binary(guidance) ->
        guidance = String.trim(guidance)

        if guidance == "" do
          {:ok, nil}
        else
          try do
            Renderer.render!(guidance, "session-override", fragments())
            {:ok, guidance}
          rescue
            error in [ArgumentError, Tightbeam.Identity.IncludeError] ->
              {:error,
               %{
                 code: "invalid_overrides",
                 message: "overrides.guidance_extra #{Exception.message(error)}"
               }}
          end
        end

      {:ok, _other} ->
        {:error,
         %{code: "invalid_overrides", message: "overrides.guidance_extra must be a string"}}
    end
  end

  defp maybe_put_override(map, _key, nil), do: map
  defp maybe_put_override(map, _key, []), do: map
  defp maybe_put_override(map, key, value), do: Map.put(map, key, value)

  defp resolve_override_guidance_lenient(nil, _fragments), do: {nil, []}

  defp resolve_override_guidance_lenient(text, fragments) do
    resolve_includes_lenient(text, fragments, [])
  end

  defp resolve_includes_lenient(text, fragments, stack) do
    {lines, discrepancies} =
      text
      |> String.split("\n")
      |> Enum.map_reduce([], fn line, discrepancies ->
        case Renderer.directive(line) do
          {:include, name} ->
            cond do
              name in stack ->
                {"",
                 discrepancies ++
                   ["guidance include cycle: #{Enum.join(Enum.reverse([name | stack]), " -> ")}"]}

              length(stack) >= 10 ->
                {"", discrepancies ++ ["guidance include depth exceeded at #{name}"]}

              true ->
                case Map.fetch(fragments, name) do
                  {:ok, content} ->
                    {resolved, nested} =
                      content
                      |> String.trim_trailing("\n")
                      |> resolve_includes_lenient(fragments, [name | stack])

                    {resolved, discrepancies ++ nested}

                  :error ->
                    {"", discrepancies ++ ["unknown guidance fragment #{inspect(name)}"]}
                end
            end

          :invalid ->
            {"", discrepancies ++ ["invalid guidance include directive"]}

          :none ->
            {line, discrepancies}
        end
      end)

    {Enum.join(lines, "\n"), discrepancies}
  end

  defp skill_available?(base_dir, identity_name, name) do
    File.exists?(Path.join([skills_dir(base_dir), name, "SKILL.md"])) or
      (is_binary(identity_name) and
         File.exists?(
           Path.join([base_dir, "identity", "pinned", identity_name, name, "SKILL.md"])
         ))
  end

  defp record_override_discrepancies(opts, discrepancies) do
    with db when not is_nil(db) <- Keyword.get(opts, :db),
         identity_name when is_binary(identity_name) <- Keyword.get(opts, :identity_name) do
      Enum.each(discrepancies, fn detail ->
        Tightbeam.EventLog.lifecycle(db, "override_discrepancy", identity_name, detail)
      end)
    else
      _ -> :ok
    end
  end

  @doc "The built-in guidance fragment library."
  @spec builtin_fragments() :: %{optional(String.t()) => String.t()}
  def builtin_fragments do
    # The operating manual is shipped content (priv/guidance/operating-manual.md),
    # the single source of truth — not a hardcoded literal that can drift from it.
    %{"operating-manual.md" => shipped_guidance!("guidance/operating-manual.md")}
  end

  defp load_fragments!(base_dir) do
    entries =
      base_dir
      |> Path.join("identity/guidance/**/*.md")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&{Path.relative_to(&1, Path.join(base_dir, "identity")), File.read!(&1)})

    catalog = Renderer.catalog!(entries)

    catalog =
      Map.put_new(catalog, "operating-manual.md", %{
        path: "substrate:priv/guidance/operating-manual.md",
        bytes: builtin_fragments()["operating-manual.md"]
      })

    Map.new(catalog, fn {name, entry} -> {name, entry.bytes} end)
  end

  @kungfu_template_paths [
    "archetypes/<name>-role.toml",
    "guidance/<name>-role.md",
    "skills/<name>-example/SKILL.md",
    "rails/<name>-example.toml",
    "kungfu/<name>/capabilities.md",
    "kungfu/<name>/preferred-models.md",
    "kungfu/<name>/intake.md",
    "kungfu/<name>/manifest.toml",
    "kungfu/<name>/README.md"
  ]

  @doc """
  The org skills LIBRARY (spec §Agent identity: "skills chosen by name from
  one shared library"): `<base_dir>/identity/skills/<name>/SKILL.md`.
  It contains org skills only; substrate baseline skills ship separately in
  `priv/skills` and their names are reserved. Archetypes elect org skills by
  name; election is validated against the library at load (an unknown name
  fails the boot — bad law stops the boot).

  Projection is BY REFERENCE (Homes): a local home gets a symlink into the
  library, so editing a skill updates every electing agent LIVE — no home
  regeneration, no memory cost. Only the election (the name list) keys the
  manifest hash; skill CONTENT deliberately does not.
  """
  @spec skills_dir(String.t()) :: String.t()
  def skills_dir(base_dir), do: Path.join([base_dir, "identity", "skills"])

  @doc "Seed the neutral three-ref served-identity repository."
  @spec init_identity!(String.t()) :: :initialized | :noop
  def init_identity!(base_dir), do: Tightbeam.Identity.init!(base_dir)

  @doc "Create a valid, unelected kungfu starter through the served-identity seam."
  @spec scaffold_kungfu!(String.t(), String.t(), String.t(), String.t()) :: [String.t()]
  def scaffold_kungfu!(base_dir, name, purpose, author) do
    name = validate_kungfu_name!(name)
    purpose = validate_kungfu_purpose!(purpose)

    entries =
      Enum.map(@kungfu_template_paths, fn template_relative ->
        relative = String.replace(template_relative, "<name>", name)

        content =
          :tightbeam
          |> Application.app_dir(Path.join("priv/kungfu-template", template_relative))
          |> File.read!()
          |> String.replace("<name>", name)
          |> String.replace("<purpose>", toml_basic_string(purpose))

        {relative, content}
      end)

    Tightbeam.Identity.scaffold!(base_dir, name, entries, author)
  end

  defp shipped_guidance!(relative_path) do
    :tightbeam
    |> Application.app_dir(Path.join("priv", relative_path))
    |> File.read!()
  end

  @doc "Walk the library: every SKILL.md as %{name, root, elected_by (roots only)}."
  @spec list_skills(String.t()) :: [
          %{name: String.t(), root: boolean(), elected_by: [String.t()]}
        ]
  def list_skills(base_dir) do
    dir = skills_dir(base_dir)
    archetypes = all()

    dir
    |> Path.join("**/SKILL.md")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      name = path |> Path.dirname() |> Path.relative_to(dir)
      root = not (name =~ "/")

      %{
        name: name,
        root: root,
        elected_by:
          if(root,
            do: for({arch_name, a} <- archetypes, name in a.skills, do: arch_name) |> Enum.sort(),
            else: []
          )
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "The built-in default archetype (used when no manifest overrides it)."
  @spec builtin_default() :: t()
  def builtin_default do
    %{
      name: "default",
      output_kind: :coordination,
      skills: [],
      where: [Tightbeam.Placement.local_host_name()],
      defaults: %{},
      references: [],
      model_preferences: [],
      containment: %{fs: :off, network: :open},
      mcp: [],
      guidance: nil,
      source: nil
    }
  end

  defp validate!(manifest, path) do
    allowed =
      MapSet.new([
        "name",
        "output_kind",
        "skills",
        "where",
        "defaults",
        "references",
        "model_preferences",
        "guidance",
        "mcp",
        "containment"
      ])

    unknown =
      manifest |> Map.keys() |> MapSet.new() |> MapSet.difference(allowed) |> MapSet.to_list()

    if unknown != [] do
      raise ArgumentError,
            "unknown top-level archetype keys in #{path}: #{unknown |> Enum.sort() |> Enum.join(", ")}"
    end

    name = Map.get(manifest, "name", Path.basename(path, ".toml"))

    unless is_binary(name) and name != "" and not String.contains?(name, "--") do
      raise ArgumentError, "archetype name must be non-empty and may not contain --: #{path}"
    end

    where = Map.get(manifest, "where", [Tightbeam.Placement.local_host_name()])
    skills = Map.get(manifest, "skills", [])
    output_kind = validate_output_kind!(Map.get(manifest, "output_kind", "artifact"), path)

    unless is_list(skills) and Enum.all?(skills, &is_binary/1) do
      raise ArgumentError, "archetype skills must be a list of strings: #{path}"
    end

    unless is_list(where) and where != [] and Enum.all?(where, &is_binary/1) do
      raise ArgumentError, "archetype where must be a non-empty list of strings: #{path}"
    end

    # "anywhere" is an EXPLICIT grant, never an accident: ["*"] and nothing
    # else. An empty list stays an error (law fails closed — in set logic an
    # empty where is nowhere, and a typo must not be the most permissive
    # value); "*" mixed with names is incoherent.
    if "*" in where and where != ["*"] do
      raise ArgumentError, ~s(archetype where: "*" must be the only element: #{path})
    end

    raw_defaults = Map.get(manifest, "defaults", %{})
    harness = raw_defaults["harness"]

    if is_binary(harness), do: Tightbeam.Harness.parse!(harness)

    # A stored default is FIELDS, not a rendering: `model` names the model,
    # `effort` and `context` are their own keys. A packed default could not
    # express a field the vendor added after it was written, and would put a
    # context variant and a reasoning level in one slot.
    defaults =
      %{}
      |> maybe_put(:harness, harness && Tightbeam.Harness.parse!(harness).id())
      |> maybe_put(:model, Tightbeam.Model.from_params(raw_defaults))

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

    model_preferences =
      validate_model_preferences!(Map.get(manifest, "model_preferences", []), path)

    mcp = validate_mcp!(Map.get(manifest, "mcp", %{}))
    containment = validate_containment!(Map.get(manifest, "containment", %{}), path)

    %{
      name: name,
      output_kind: output_kind,
      skills: skills,
      where: where,
      model_preferences: model_preferences,
      containment: containment,
      defaults: defaults,
      references: references,
      mcp: mcp,
      guidance: get_in(manifest, ["guidance", "text"])
    }
  end

  defp validate_output_kind!(kind, _path) when kind in ~w(coordination artifact verdict),
    do: String.to_existing_atom(kind)

  defp validate_output_kind!(_kind, path) do
    raise ArgumentError,
          "archetype output_kind must be coordination, artifact, or verdict: #{path}"
  end

  # A stored preference holds FIELDS, like every other stored selection: a
  # table with `model`, and optionally `effort` and `context`.
  #
  #     [[model_preferences]]
  #     model = "claude-fable-5"
  #     effort = "high"
  #
  # A list of packed strings — the shape this used to take — is REFUSED by
  # name rather than parsed. Splitting `claude-fable-5[1m]` here is exactly the
  # guess that lost the 1M model, and a file an older version wrote deserves a
  # bug report, not an inference.
  defp validate_model_preferences!(raw, path) do
    unless is_list(raw) do
      raise ArgumentError, "archetype model_preferences must be a list of tables: #{path}"
    end

    Enum.map(raw, fn
      preference when is_map(preference) ->
        case Tightbeam.Model.from_params(preference) do
          nil ->
            raise ArgumentError,
                  "archetype model_preferences entry is missing model: #{path}"

          model ->
            model
        end

      packed when is_binary(packed) ->
        raise ArgumentError,
              "archetype model_preferences entry #{inspect(packed)} is a packed string; " <>
                "a preference is fields — [[model_preferences]] with model/effort/context: " <>
                path

      other ->
        raise ArgumentError,
              "archetype model_preferences entry must be a table, got #{inspect(other)}: #{path}"
    end)
  end

  defp validate_containment!(raw, path) do
    unknown =
      raw
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.difference(MapSet.new(["fs", "network"]))
      |> MapSet.to_list()

    if unknown != [] do
      raise ArgumentError,
            "unknown containment keys in #{path}: #{unknown |> Enum.sort() |> Enum.join(", ")}"
    end

    fs = Map.get(raw, "fs", "off")
    network = Map.get(raw, "network", "open")

    unless fs == "off" do
      raise ArgumentError, "archetype containment.fs must be off: #{path}"
    end

    unless network == "open" do
      raise ArgumentError, "archetype containment.network must be open: #{path}"
    end

    %{fs: String.to_existing_atom(fs), network: :open}
  end

  defp validate_mcp!(servers) do
    # Deterministic NAME order: manifest order would carry no semantics
    # (the harness receives a set) and recovering it from TOML would mean
    # re-parsing raw text — complexity with no law behind it.
    order = servers |> Map.keys() |> Enum.sort()

    Enum.map(order, fn name ->
      unless Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, name) do
        raise ArgumentError, "invalid mcp server name: #{name}"
      end

      server = Map.fetch!(servers, name)
      allowed = MapSet.new(["command", "args", "env"])

      unknown =
        server |> Map.keys() |> MapSet.new() |> MapSet.difference(allowed) |> MapSet.to_list()

      if unknown != [] do
        raise ArgumentError,
              "mcp server #{name}: unknown mcp server keys: #{unknown |> Enum.sort() |> Enum.join(", ")}"
      end

      command = server["command"]

      unless is_binary(command) and command != "" do
        raise ArgumentError, ~s(mcp server #{name} is missing "command")
      end

      args = Map.get(server, "args", [])

      unless is_list(args) and Enum.all?(args, &is_binary/1) do
        raise ArgumentError, "mcp server #{name}: args must be a list of strings"
      end

      env = Map.get(server, "env", %{})

      unless is_map(env) and
               Enum.all?(env, fn {key, value} -> is_binary(key) and is_binary(value) end) do
        raise ArgumentError, "mcp server #{name}: env must be string keys and values"
      end

      %{name: name, command: command, args: args, env: env}
    end)
  end

  defp validate_kungfu_name!(name) do
    valid? =
      is_binary(name) and Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, name) and
        not String.contains?(name, "--") and not String.ends_with?(name, "-")

    unless valid?, do: raise(ArgumentError, "invalid kungfu name: #{inspect(name)}")
    name
  end

  defp validate_kungfu_purpose!(purpose) do
    unless is_binary(purpose) and String.trim(purpose) != "" do
      raise ArgumentError, "kungfu purpose is required"
    end

    purpose
  end

  defp toml_basic_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\b", "\\b")
      |> String.replace("\t", "\\t")
      |> String.replace("\n", "\\n")
      |> String.replace("\f", "\\f")
      |> String.replace("\r", "\\r")

    ~s("#{escaped}")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
