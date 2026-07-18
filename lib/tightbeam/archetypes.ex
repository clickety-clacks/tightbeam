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
      where = ["work-1", "work-2"]      # allowed host-set (§Placement).
                                        # Optional; default ["local"].
                                        # ["*"] alone = any configured host.
                                        # Empty = error, never a grant.

      [defaults]                        # optional spawn defaults
      harness = "codex"                 # "claude" | "codex"
      model   = "gpt-5.6-sol[medium]"

      fallback_models = ["fable"]       # optional PREFERENCE chain (may cross
                                        # harnesses). Data only: surfaced to
                                        # clients; SWITCHING is a reaction
                                        # rail (deliberate, audited), never
                                        # silent substrate retry.

      [references]                      # optional — named pointers to work
                                        # materials; compile into guidance
                                        # TEXT, never substrate machinery
                                        # (point at the docs; copy the
                                        # identity; move the credentials
                                        # never).
      repo = { location = "work-1:~/src/example-repo", access = "git; gate: run the tests" }

      [guidance]                        # optional extra guidance, appended
      text = \"\"\"...\"\"\"

  A built-in "default" archetype always exists (where ["local"], no
  references, no defaults) so a fresh install works with zero manifests. A
  manifest file named default.toml OVERRIDES the built-in.

  GUIDANCE FRAGMENTS (spec §Agent identity): shared guidance lives as files
  in `<base_dir>/identity/guidance/*.md` and is composed via an include
  directive — a line of exactly `#include "fragment.md"` — resolved
  recursively at compile time. Includes are parts-listing in-text and
  nothing more: no variables, no conditionals, no logic (a template that can
  compute is an agent that can't be audited). The substrate ships two
  built-in fragments every home receives — "preamble.md" (the standing
  preamble) and "scheduling-wakes.md" (the CLI skill) — and an operator
  fragment of the same name OVERRIDES the built-in. Resolution is validated
  at load!: a missing fragment or an include cycle fails the boot. Because
  composition happens before the projection hash, editing a fragment
  regenerates exactly the homes that include it.

  Loading is boot-time and whole-set: `load!/1` parses every manifest,
  validates (unknown top-level keys are ERRORS — a typo'd field must not
  silently become no-op law), and stores the set in `:persistent_term`
  (read-heavy, write-once-per-boot; identity changes re-load on restart —
  live reload is a later concern). A malformed manifest fails the boot: bad
  law should stop the boot, not limp.

  Guidance compilation produces the FULL instructions file content for a
  home: the archetype header, the standing preamble and orientation, the
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
          fallback_models: [String.t()],
          guidance: String.t() | nil
        }

  @builtin_orientation """
  You did not start this session: Tightbeam called it into being. The
  substrate composed the identity you are reading right now, placed you on
  this machine, holds your address and your mailbox, delivers every prompt
  that reaches you — from the operator or from other sessions — and keeps
  your history and identity safe across restarts and moves. Between turns
  you are not running; you are woken. That is not a limitation. It is how
  you persist.

  - Your identity comes from an ARCHETYPE — a template of guidance, skills,
    defaults, and WHERE (the machines its sessions may inhabit). You may
    carry a handle (like coder:x); that is how colleagues address you.
  - A WAKE is how anything reaches a session: a prompt, delivered now or on
    a schedule. DMing a colleague and scheduling your own follow-up are the
    same mechanism.
  - Other sessions were called into being exactly as you were: colleagues
    with their own identities and mailboxes, not subprocesses. You can hire
    more (spawn) and address them by handle.
  - Discovery first, guessing never: `tightbeam list` shows the sessions you
    can address and the org's shape — archetypes with their WHERE, the known
    hosts, and the valid model catalog per harness. Use model refs from the
    catalog verbatim; never invent one.
  - The machine you run on is a workplace chosen from your archetype's
    WHERE. Your identity, mailbox, and chat history live in the substrate
    and survive any machine — including a move.
  - The OPERATOR is the human whose org this is. Anything the substrate
    refuses, it refuses with a reason naming the rule.
  """

  @builtin_operations """
  You operate this org through the `tightbeam` CLI, and you speak about its
  operations WITH AUTHORITY: consult `tightbeam list` for current state,
  then answer definitively — never "probably". Facts you may state without
  hedging:

  - `spawn` creates a session: --display (label), --name (its handle),
    --archetype, --harness claude|codex, --model <ref>, --host <name>,
    --key <idempotency-key>. Placement rule: the host must be in the
    archetype's WHERE; omitted, the first allowed host is used. An unknown
    archetype, a disallowed host, or an invented model ref is REFUSED with
    the rule named — nothing half-happens.
  - Model refs come ONLY from the catalog shown by `tightbeam list` (per
    harness; effort variants look like name[medium]). A model not in the
    catalog does not exist here — say so plainly.
  - `wake <target> --prompt "..."` delivers a prompt now (that is a DM) or
    later (--after 5m / --at <epochMs>). Incoming wakes arrive stamped
    `[from <origin>]` — that is the RETURN ADDRESS. When a colleague wakes
    YOU, your reply lands in YOUR stream — to answer them, wake the stamped
    origin back (a `[from ...]` bearing your own handle is your earlier self
    following up; act, don't reply).
  - `tune` changes a session (rename, set_model, set_host — set_host moves
    it to another allowed machine); `retire` ends one (its history
    survives); `cancel-wake <id>` cancels a scheduled wake.
  - `assimilate <ssh-dest>` (admin) prepares a machine over ssh and
    registers it as a host; registered hosts appear in `list` and become
    usable in archetype WHERE lists.
  - Every action is attributed: --as <your-handle> (you) or --as-user
    <human>. You cannot act as anyone you are not.
  """

  @builtin_preamble """
  You are a resident session of a Tightbeam org. The Orientation below
  explains your existence here; the scheduling-wakes skill after it is how
  you speak to the rest of the org.
  """

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

    fragments =
      [base_dir, "identity", "guidance"]
      |> Path.join()
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reduce(builtin_fragments(), fn path, acc ->
        Map.put(acc, Path.basename(path), File.read!(path))
      end)

    # Validate ALL law at load: every archetype's guidance must compose
    # (missing fragments and include cycles fail the boot, not a turn).
    for {_name, archetype} <- archetypes, do: guidance_with(archetype, fragments)

    :persistent_term.put(@persist_key, {archetypes, fragments})
    archetypes
  end

  @doc "The loaded fragment library — built-ins overridden by identity/guidance files."
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
  def guidance(archetype), do: guidance_with(archetype, fragments())

  defp guidance_with(archetype, fragments) do
    preamble =
      [
        "# Tightbeam · #{archetype.name}",
        "",
        resolve_includes(~s(#include "preamble.md"), fragments, []),
        "",
        "## Orientation",
        resolve_includes(~s(#include "orientation.md"), fragments, []),
        "",
        "## Operations",
        resolve_includes(~s(#include "operations.md"), fragments, []),
        "",
        "## Skill: scheduling-wakes",
        resolve_includes(~s(#include "scheduling-wakes.md"), fragments, [])
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

    with_materials = if materials, do: preamble <> "\n\n" <> materials, else: preamble

    if archetype.guidance do
      with_materials <> "\n\n" <> resolve_includes(archetype.guidance, fragments, [])
    else
      with_materials
    end
  end

  # Include resolution: a line of exactly `#include "name.md"` is replaced by
  # the named fragment, itself resolved (stack detects cycles; depth-capped).
  # No other line is touched — includes only, never logic.
  defp resolve_includes(text, fragments, stack) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      case Regex.run(~r/^#include "([^"]+)"\s*$/, line) do
        [_, name] ->
          cond do
            name in stack ->
              raise ArgumentError,
                    "guidance include cycle: #{Enum.join(Enum.reverse([name | stack]), " -> ")}"

            length(stack) >= 10 ->
              raise ArgumentError, "guidance include depth exceeded at #{name}"

            true ->
              case Map.fetch(fragments, name) do
                {:ok, content} ->
                  content |> String.trim_trailing("\n") |> resolve_includes(fragments, [name | stack])

                :error ->
                  raise ArgumentError,
                        "unknown guidance fragment #{inspect(name)}; available: " <>
                          (fragments |> Map.keys() |> Enum.sort() |> Enum.join(", "))
              end
          end

        nil ->
          line
      end
    end)
    |> Enum.join("\n")
  end

  defp builtin_fragments do
    %{
      "preamble.md" => @builtin_preamble,
      "orientation.md" => @builtin_orientation,
      "operations.md" => @builtin_operations,
      "scheduling-wakes.md" => @scheduling_wakes_skill
    }
  end

  @doc "The built-in default archetype (used when no manifest overrides it)."
  @spec builtin_default() :: t()
  def builtin_default do
    %{
      name: "default",
      where: ["local"],
      defaults: %{},
      references: [],
      fallback_models: [],
      guidance: nil
    }
  end

  defp validate!(manifest, path) do
    allowed = MapSet.new(["name", "where", "defaults", "references", "fallback_models", "guidance"])

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

    # "anywhere" is an EXPLICIT grant, never an accident: ["*"] and nothing
    # else. An empty list stays an error (law fails closed — in set logic an
    # empty where is nowhere, and a typo must not be the most permissive
    # value); "*" mixed with names is incoherent.
    if "*" in where and where != ["*"] do
      raise ArgumentError, ~s(archetype where: "*" must be the only element: #{path})
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
    fallback_models = Map.get(manifest, "fallback_models", [])

    unless is_list(fallback_models) and Enum.all?(fallback_models, &is_binary/1) do
      raise ArgumentError, "archetype fallback_models must be a list of strings: #{path}"
    end


    %{
      name: name,
      where: where,
      fallback_models: fallback_models,
      defaults: defaults,
      references: references,
      guidance: get_in(manifest, ["guidance", "text"])
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
