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
      skills = ["tightbeam-assimilate"] # election from the shared skills
                                        # library (identity/skills/<name>/
                                        # SKILL.md). Omitted = the built-in
                                        # set; named = exactly that list.
                                        # Unknown names fail the boot.
      where = ["work-1", "work-2"]      # allowed host-set (§Placement).
                                        # Optional; default: the gateway's
                                        # own hostname.
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

  A built-in "default" archetype always exists (where = the gateway's own
  hostname, no references, no defaults) so a fresh install works with zero
  manifests. A
  manifest file named default.toml OVERRIDES the built-in.

  GUIDANCE FRAGMENTS (spec §Agent identity): shared guidance lives as files
  in `<base_dir>/identity/guidance/*.md` and is composed via an include
  directive — a line of exactly `#include "fragment.md"` — resolved
  recursively at compile time. Includes are parts-listing in-text and
  nothing more: no variables, no conditionals, no logic (a template that can
  compute is an agent that can't be audited). The substrate ships the
  built-in "operating-manual.md" fragment to every home, and an operator
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
  home: the archetype header, the standing operating manual, the references
  section rendered as "## Your materials" (name, location, access notes),
  then any manifest guidance text. Compilation is pure — same manifest, same
  bytes — because home projection is hash-gated on its output.
  """

  @persist_key __MODULE__

  @typedoc "A validated archetype."
  @type t :: %{
          name: String.t(),
          skills: [String.t()],
          where: [String.t()],
          defaults: %{optional(:harness) => :claude | :codex, optional(:model) => String.t()},
          references: [%{name: String.t(), location: String.t(), access: String.t() | nil}],
          fallback_models: [String.t()],
          containment: %{fs: :off | :workdir, network: :open},
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

  @builtin_operating_manual """
  # Operating tightbeam

  You run your work through the `tightbeam` command. Its output is JSON on stdout; a nonzero
  exit is a failure, with the reason on stderr. Command examples in this manual use example
  names — a user `mike`, a `reviewer` role, a model `gpt-5.6-sol[high]`; substitute the real
  ids from your org and its catalog.

  ## Where you are
  You are an agent — one running session, with an address, an owner, and a job — inside
  tightbeam, where AI agents coordinate to do work for a person (the user). Other agents are
  your colleagues; you reach them and hire more. Tightbeam woke you because there is something
  to do. It holds your identity, mailbox, and history across restarts and machine moves. When
  tightbeam refuses a command, it names the rule that refused it. Read the reason.

  ## See what is around you
  Run `tightbeam list`. It returns the sessions you can address, the archetypes in this org,
  the hosts (machines agents run on), and the model catalog (the model names you may use). Use
  a model name from that catalog exactly.

  ## Identity: who a command is attributed to
  Tightbeam attributes every command to an identity — the accountability record of who acted.
  In a session's own workdir, tightbeam derives the identity from the session credential and
  no identity flag is required. Use `--as <role>` to attribute the command to a specific role
  the session holds. Use `--as-user <id>` to attribute it to the human. An identity is who the
  command is attributed to, not its target.

  ## Talk to a colleague: wake
  Agents communicate by waking each other — delivering a prompt to a mailbox:

      tightbeam wake --role reviewer --prompt "review the auth change"

  That delivers a message now. To deliver it later, add `--after 30m` or `--at <epochMs>`.
  Every wake carries a prompt. To answer a prompt tagged `[from user:mike]`, run
  `wake --user mike`; tagged `[from role:notetaker]`, run `wake --role notetaker`.

  ## Wake yourself to work later
  You run only when woken. To do deferred work — wait for a build, check back on a colleague,
  retry after a delay, or resume a long task — schedule a wake to your own role and add
  `--after`/`--at`:

      tightbeam wake --role <your-role> --prompt "check if the build finished, then continue" --after 10m

  The prompt you send yourself instructs the future you. Cancel a scheduled wake with
  `tightbeam cancel-wake <wakeId>`, using the id the wake command returned.

  ## Work with colleagues without disrupting them
  Ask a colleague when that colleague can answer something you need to do your job. Do not send
  idle status requests or nudges. Send routine progress to your owner.

  ## Hire help: spawn and retire
  Start a new session:

      tightbeam spawn --display "Reviewer" --name reviewer --harness codex --model "gpt-5.6-sol[high]"

  `--display` is the human label; `--name` registers a role bound to the new session so you can
  address it. Add `--archetype <name>` to give the session that archetype's identity — its
  guidance, skills, and allowed hosts; add `--host <name>` to place it on a machine the
  archetype allows. End a session with `tightbeam retire --session <key>`; its history is kept.
  Pass `--key <idempotencyKey>` on a spawn, assign, or wake you may retry, so the retry does not
  create a duplicate.

  ## Track work: work-items, assignments, facts
  Work is tracked as durable records, not in chat.
  - A work-item is the durable thread for one feature or bug:

      tightbeam work-item-create --title "voice dictation crash on resume"

  - An assignment is an obligation on that work, held by a session:

      tightbeam assign --subject "fix the resume crash" --role coder --work-item <workItemId>

  - Record what happens against your assignment with attest:

      tightbeam attest <assignmentId> --kind progress   --note "root-caused to a nil token"
      tightbeam attest <assignmentId> --kind completion --note "fixed; tests green"
      tightbeam attest <assignmentId> --kind surrender  --note "blocked on device access"

  - Record a judgment — a review, a test outcome, the user's decision — as a verdict:

      tightbeam attest <assignmentId> --kind verdict --verdict reviewed-clean --note "…"

  These facts are the state of the work. The state is computed from the facts; there is no
  status to set. Read the facts with `tightbeam attests <assignmentId>`. List your obligations
  with `tightbeam assignments --role <your-role>`.

  ## Recover after losing context
  You can lose context to compaction or a restart. On waking, re-derive the state from the
  facts — read the work-item and its attests. Read the facts; do not rely on prior scrollback.

  ## Where your files live
  Your workdir is your durable artifact space: it survives restarts, home regeneration, and
  machine moves. Everything durable you produce — checkouts, drafts, evidence — belongs in
  your workdir. Your home is substrate-owned identity: the substrate may regenerate it at any
  time, and anything loose in it is forfeit. Keep work out of your home and out of system temp
  directories.

  ## Never end a turn with open work and nothing on the clock
  While you hold an open assignment, end every turn with a filing — progress, completion, or
  surrender — or a scheduled continuation wake to yourself. A turn that ends with neither is a
  stall: the substrate prods you, naming the assignment, and prods that go unanswered escalate
  to the session that spawned you.

  ## Work alongside other agents
  Other agents work in the same places at the same time. Another agent's in-progress material
  is not yours to discard, and it is not a blocker to stall on. Reconcile it: identify who or
  what created it, and either ask that owner to resolve it, or remove it yourself once you
  have established it is safe to remove (abandoned, yours, or the owner agrees). Do your own
  work in your own workspace. Examples: a git worktree holding uncommitted changes that are
  not yours — do not stash, reset, or clean it; a shared document another session is
  mid-edit on — do not overwrite or revert it.

  ## When a rule stops a command
  A rule can stop a command and name itself. Do not route around it. Take a path that does not
  break the rule, or change what you are building. A rule that repeatedly stops you indicates
  the approach is wrong.

  ## When a decision is the user's
  A decision that belongs to the user, and any vague point the work depends on (a spec hole on
  a concept the work is built on), goes to the user. Do not guess and do not stall: ask. The
  work waits until the user answers; the answer is recorded as a fact and releases the work.

  ## Report so the user can act
  - Support every claim with its source — a file and line, a log line, a specific commit.
  - Report state the user can act on: what changed, what is ready, what remains, who acts next,
    what decision you need.
  - "Done" means the user can try it.
  - State what an identifier means, not the bare identifier: "the fix that stops the resume
    crash," not "abc123."
  - To keep something, record it now (work-item, memory, or guidance). Do not defer it to
    memory of your own.
  """

  @builtin_assimilation """
  Assimilation onboards a machine as a host. It is a CEREMONY you can run
  end-to-end when the operator asks — no source-diving, no guessing; this
  section is the complete procedure.

  1. `tightbeam assimilate <ssh-dest> --as-user <operatorId>` (admin act —
     run it AS the operator who asked). <ssh-dest> is anything ssh resolves
     (tailnet names work). Preconditions the probe checks for you: key-based
     ssh access and node on the target. Useful flags: --name <hostname>
     (defaults from the destination), --harness claude,codex, --dry-run.
  2. Credentials. Doctrine: every {org, host, harness} gets its OWN grant —
     the ceremony's ONBOARD step runs the harness's login on the satellite,
     which needs an interactive terminal. YOU do not have one: assimilate
     will print the per-harness login commands instead — relay them to the
     operator VERBATIM and say plainly that this step is theirs. A
     "credentials missing" result is not failure: the host registers anyway
     and degrades visibly (turns there fail with an auth marker) until the
     operator onboards it. Never work around this with --push-credentials
     unless the operator explicitly chooses it — pushed copies share a
     grant, and shared grants revoke each other on refresh.
  3. Allow placement. A registered host is usable only where an archetype's
     WHERE admits it. Archetypes are TOML manifests at
     `$TIGHTBEAM_HOME/identity/archetypes/<name>.toml`. The built-in
     "default" archetype has NO file; writing `default.toml` overrides it —
     minimal contents to admit a new host alongside the gateway's own:

         name = "default"
         where = ["<gateway-host>", "<new-host>"]

     Editing `where` alone never touches guidance, so it costs no session
     its memory.
  4. Restart to apply. Archetype manifests load at substrate BOOT: a
     manifest edit takes effect at the next gateway restart, not before.
     Say so in your report — "registered and allowed; takes effect on the
     next substrate restart" — and never sit waiting for it silently.
  5. Verify. After the restart: the host appears in `tightbeam list`, and
     `spawn --host <name>` places a session there.
  """

  @builtin_skill_mgmt """
  You can manage this org's skill library — the shared body of on-demand
  knowledge every archetype elects from. This is the complete procedure;
  no source-diving, no guessing.

  WHAT SKILLS ARE HERE. The library lives at
  `$TIGHTBEAM_HOME/identity/skills/<name>/SKILL.md` and is REPLICATED to
  every host; your home's `skills/` entries are symlinks into your host's
  replica. Two shapes, one mechanism:
  - A ONE-SHOT skill: one directory, its SKILL.md, any support files.
  - A SUBJECT TREE: a directory whose root SKILL.md is a routing MANIFEST
    over nested technique skills ("structured concurrency →
    `concurrency/SKILL.md`"), each technique a subdirectory with its own
    SKILL.md. When AUTHORING a tree: the parent teaches nothing itself —
    it routes, with relative paths and one line on when each child
    applies.

  OPERATING ON THE LIBRARY (admin verbs — run --as-user the operator who
  asked):
  - `tightbeam skill list` — every skill, tree membership, who elects it.
  - `tightbeam skill put <name> --file <path>` — create or update. <name>
    may be a tree path ("swift/concurrency"). The write propagates to
    every host's replica IMMEDIATELY; a host reported as "error: ..." is
    degraded, not failed — it heals at its next home delivery. Content
    edits are LIVE for every electing agent and never cost anyone memory.
  - `tightbeam skill rm <name>` — remove. Refused for a root any
    archetype elects (retire the election first); pruning inside an
    elected tree is an ordinary edit.

  ELECTION is separate from content: an archetype names its skills in its
  manifest (`skills = [...]` in
  `$TIGHTBEAM_HOME/identity/archetypes/<name>.toml`; omitted = the
  built-in set). Election is ATOMIC at tree roots — electing a subject
  takes the whole tree; nested names are invalid. Election edits are
  IDENTITY changes: they apply at the next substrate restart and
  regenerate the electing homes (sessions there lose model memory,
  visibly, via the context-reset marker). Say both facts in your report
  when you change an election.
  """

  @builtin_harness_matrix """
  Per-harness feature support: FACTS, not guesses. Consult this before
  promising any feature on a specific harness; a feature not listed here
  diverges nowhere. Never say "probably" about a row below.

  claude (via claude-agent-acp):
  - Skills: NATIVE — discovered from your home's skills/ dir, invoked via
    the Skill tool.
  - Rails gates: ENFORCED — PreToolUse hooks refuse matching tool calls
    before execution; a refusal quoting "[gate: <name>]" is the runtime
    acting, not the model declining.
  - Credentials: .credentials.json file OR a long-lived setup-token grant
    injected as env (the rotation-proof form).
  - Slash commands: /clear /compact /model verified as passthrough.
  - Emits per-turn context-usage telemetry.

  codex (via codex-acp):
  - Skills: NO native discovery — the same skill files exist at the same
    paths in your home; READ them when the operator asks (the Operations
    pointer names the path).
  - Rails gates: ENFORCED FOR NON-MALICIOUS AGENTS — the same compiled
    PreToolUse hooks as claude, delivered as hooks.json and WIRING-CHECKED
    at adapter spawn: the substrate proves a probe command is refused before
    serving sessions, and a codex adapter that cannot prove it does not come
    up. The refusal envelope is "Command blocked by PreToolUse hook: [gate:
    <name>] …" — the runtime acting, not the model declining. This is
    enumerated-call denial for a cooperative-but-forgetful agent, NOT a
    sandbox or tamper-proof; malicious and config-hostile actors are out of
    scope, exactly as for claude rails.
  - Credentials: auth.json via codex login only; no token-env equivalent,
    so the rotation caveat applies to shared logins.
  - Slash-command vocabulary differs from claude and is unverified — do
    not promise specific commands.
  - Verified working (2026-07-18): turns, tool use, AGENTS.md identity,
    read-on-demand skills, gpt-5.6-sol model selection. Headless login
    exists: codex login --device-auth.

  Both: sessions/turns/cancel/load, model+effort selection, projected
  identity (CLAUDE.md vs AGENTS.md), hash-gated homes with surviving
  session state, harness switching with the history barrier. Neither:
  structured compaction events — compaction is invisible to the substrate
  today. The full matrix with mechanisms lives in the spec repo
  (harness-support.md); if reality disagrees with this skill, say so and
  flag the operator — this file is maintained law, not folklore.
  """

  @builtin_skills %{
    "tightbeam-harnesses" =>
      """
      ---
      name: tightbeam-harnesses
      description: Per-harness feature support matrix (claude vs codex) — what works where and by what mechanism. Consult before promising or relying on a harness-specific feature.
      ---

      """ <> @builtin_harness_matrix,
    "tightbeam-skills" =>
      """
      ---
      name: tightbeam-skills
      description: Manage the org's skill library — create, update, structure (one-shot skills and subject trees), and remove skills via the skill verbs. Use when the operator asks to add or change skills.
      ---

      """ <> @builtin_skill_mgmt,
    "tightbeam-assimilate" =>
      """
      ---
      name: tightbeam-assimilate
      description: Onboard a machine as a tightbeam host — the complete assimilation ceremony (probe, credentials, archetype WHERE, restart, verify). Use when the operator asks to assimilate a machine.
      ---

      """ <> @builtin_assimilation,
    "tightbeam-dispatching" => """
    ---
    name: tightbeam-dispatching
    description: Assignment and attest hygiene when dispatching work to another session or holding an assignment yourself. Use when hiring, delegating, or working under an open assignment.
    ---

    Dispatching work: spawn (or pick) the worker, then open the
    obligation as a row — `tightbeam assign --subject "..."
    (--session K | --role R)` — and wake the worker with the brief.
    Done is rows, not prose: the assignment closes only by the holder's
    completion or surrender attest, or the operator's revoke.

    Holding an assignment: every turn you end must leave a filing
    (`tightbeam attest <id> --kind progress|completion|surrender
    [--note "..."]`) or a continuation wake on the clock. Progress rows
    reset the prod countdown; scheduled wakes pause it; words do
    neither. If you stall, prods arrive from process:tightbeam and
    escalate up your spawner chain after N misses.

    Supervising: an escalation wake means your hire's assignment
    stalled — N prods, no rows. Judgment is yours: read their stream,
    wake them, re-staff, or ask the operator to revoke the assignment.
    The substrate will not conclude why and will not act for you.
    """
  }

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

    materialize_builtin_skills!(base_dir)

    library =
      base_dir
      |> skills_dir()
      |> Path.join("*/SKILL.md")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
      |> MapSet.new()

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

  defp materialize_builtin_skills!(base_dir) do
    for {name, content} <- @builtin_skills do
      path = Path.join([skills_dir(base_dir), name, "SKILL.md"])

      unless File.exists?(path) do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
      end
    end
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
    preamble =
      [
        "# Tightbeam · #{archetype.name}",
        "",
        resolve_includes(~s(#include "operating-manual.md"), fragments, [])
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
                  content
                  |> String.trim_trailing("\n")
                  |> resolve_includes(fragments, [name | stack])

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

          unknown =
            skills |> Enum.uniq() |> Enum.reject(&MapSet.member?(roots, &1)) |> Enum.sort()

          if unknown == [] do
            normalized =
              skills |> Enum.uniq() |> Enum.reject(&(&1 in archetype.skills)) |> Enum.sort()

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
            resolve_includes(guidance, fragments(), [])
            {:ok, guidance}
          rescue
            error in ArgumentError ->
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
        case Regex.run(~r/^#include "([^"]+)"\s*$/, line) do
          [_, name] ->
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

          nil ->
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
    %{
      "operating-manual.md" => @builtin_operating_manual
    }
  end

  @doc """
  The shared skills LIBRARY (spec §Agent identity: "skills chosen by name
  from one shared library"): `<base_dir>/identity/skills/<name>/SKILL.md`.
  Built-in skills are materialized into the library at load — only when the
  file is ABSENT, so an operator's edit always wins and deleting the file
  restores the built-in at next boot. Archetypes elect skills by name;
  election is validated against the library at load (an unknown name fails
  the boot — bad law stops the boot).

  Projection is BY REFERENCE (Homes): a local home gets a symlink into the
  library, so editing a skill updates every electing agent LIVE — no home
  regeneration, no memory cost. Only the election (the name list) keys the
  manifest hash; skill CONTENT deliberately does not.
  """
  @spec skills_dir(String.t()) :: String.t()
  def skills_dir(base_dir), do: Path.join([base_dir, "identity", "skills"])

  @doc "Seed the identity working tree and create its initial git commit."
  @spec init_identity!(String.t()) :: :initialized | :noop
  def init_identity!(base_dir) do
    identity_dir = Path.join(base_dir, "identity")

    if File.exists?(Path.join(identity_dir, ".git")) do
      :noop
    else
      for directory <- ["archetypes", "guidance", "skills", "rails", "rules"] do
        File.mkdir_p!(Path.join(identity_dir, directory))
      end

      materialize_builtin_skills!(base_dir)

      write_unless_exists!(
        Path.join([identity_dir, "archetypes", "default.toml"]),
        builtin_default_toml()
      )

      for {name, content} <- builtin_fragments() do
        write_unless_exists!(Path.join([identity_dir, "guidance", name]), content)
      end

      for directory <- ["rails", "rules"] do
        write_unless_exists!(Path.join([identity_dir, directory, ".gitkeep"]), "")
      end

      git!(identity_dir, ["init"])
      git!(identity_dir, ["add", "-A"])
      git!(identity_dir, ["commit", "-m", "seed: tightbeam defaults"], "tightbeam")
      :initialized
    end
  end

  @doc "Built-in skill names — the default election when a manifest names none."
  @spec builtin_skill_names() :: [String.t()]
  def builtin_skill_names, do: @builtin_skills |> Map.keys() |> Enum.sort()

  @doc """
  Library CRUD (the skill verbs' engine — mutation reaches here only
  through the chokepoint). `name` is a relative path of plain segments:
  a top-level name is a one-shot skill or a tree ROOT; a nested path
  ("swift/concurrency") is a technique inside a subject tree. Only roots
  are electable (election is atomic at the root — electing a subject takes
  the whole tree); writing inside a tree is a content edit, visible to
  every electing agent through the replica links, never a regeneration.
  """
  @spec put_skill!(String.t(), String.t(), String.t()) :: String.t()
  def put_skill!(base_dir, name, content) do
    put_skill!(base_dir, name, content, "tightbeam")
  end

  @spec put_skill!(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def put_skill!(base_dir, name, content, author) do
    init_identity!(base_dir)
    path = Path.join([skills_dir(base_dir), validate_skill_path!(name), "SKILL.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    commit_identity!(base_dir, [path], "skill-put: #{name}", author)
    path
  end

  @doc """
  Remove a skill (or tree node). Removing an elected root is a transform:
  the library content is deleted and the current manifest electors and
  restart warnings are returned to the caller. Boot validation remains
  fail-closed until those manifests are edited. Pruning inside a tree is a
  content edit and has no electors.
  """
  @spec rm_skill(String.t(), String.t()) ::
          {:ok, %{archetype_electors: [String.t()], manifest_warnings: [String.t()]}}
          | {:error, %{code: String.t(), message: String.t()}}
  def rm_skill(base_dir, name) do
    rm_skill(base_dir, name, "tightbeam", [])
  end

  @spec rm_skill(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, %{archetype_electors: [String.t()], manifest_warnings: [String.t()]}}
          | {:error, %{code: String.t(), message: String.t()}}
  def rm_skill(base_dir, name, author, additional_paths) do
    init_identity!(base_dir)
    relative = validate_skill_path!(name)
    path = Path.join(skills_dir(base_dir), relative)

    if not File.exists?(path) do
      {:error, %{code: "unknown_skill", message: "unknown skill: #{relative}"}}
    else
      {:ok, removal} = remove_skill(path, relative)
      commit_identity!(base_dir, [path | additional_paths], "skill-rm: #{name}", author)
      {:ok, removal}
    end
  end

  defp remove_skill(path, relative) do
    electors =
      if relative =~ "/" do
        []
      else
        for {arch_name, archetype} <- all(), relative in archetype.skills, do: arch_name
      end

    electors = Enum.sort(electors)

    warnings =
      Enum.map(electors, fn archetype_name ->
        archetype = Map.fetch!(all(), archetype_name)
        file = if archetype.source, do: archetype.source.file, else: "builtin default"

        "archetype #{archetype_name} still elects #{relative} in #{file} — " <>
          "edit it before the next restart (boot validation is fail-closed)"
      end)

    File.rm_rf!(path)
    {:ok, %{archetype_electors: electors, manifest_warnings: warnings}}
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

  # A skill path is dumb data with teeth: plain relative segments only —
  # no traversal, no absolutes, no hidden files (the library is reachable
  # by ssh-wrapped rsync; a crafted name must not escape it).
  defp validate_skill_path!(name) do
    segments = String.split(name, "/")

    valid? =
      segments != [] and
        Enum.all?(segments, fn seg ->
          seg != "" and seg != "." and seg != ".." and not String.starts_with?(seg, ".") and
            seg =~ ~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/
        end)

    unless valid?, do: raise(ArgumentError, "invalid skill name: #{inspect(name)}")
    Enum.join(segments, "/")
  end

  @doc "The built-in default archetype (used when no manifest overrides it)."
  @spec builtin_default() :: t()
  def builtin_default do
    %{
      name: "default",
      skills: builtin_skill_names(),
      where: [Tightbeam.Placement.local_host_name()],
      defaults: %{},
      references: [],
      fallback_models: [],
      containment: %{fs: :off, network: :open},
      mcp: [],
      guidance: nil,
      source: nil
    }
  end

  defp builtin_default_toml do
    archetype = builtin_default()

    [
      "name = #{JSON.encode!(archetype.name)}",
      "skills = [#{Enum.map_join(archetype.skills, ", ", &JSON.encode!/1)}]",
      "where = [#{Enum.map_join(archetype.where, ", ", &JSON.encode!/1)}]",
      "fallback_models = [#{Enum.map_join(archetype.fallback_models, ", ", &JSON.encode!/1)}]",
      "",
      "[defaults]",
      "",
      "[references]",
      "",
      "[guidance]",
      "",
      "[mcp]",
      "",
      "[containment]",
      "fs = #{JSON.encode!(Atom.to_string(archetype.containment.fs))}",
      "network = #{JSON.encode!(Atom.to_string(archetype.containment.network))}",
      ""
    ]
    |> Enum.join("\n")
  end

  defp write_unless_exists!(path, content) do
    unless File.exists?(path), do: File.write!(path, content)
  end

  defp commit_identity!(base_dir, paths, message, author) do
    identity_dir = Path.join(base_dir, "identity")

    relative_paths = Enum.map(paths, &Path.relative_to(&1, identity_dir))
    git!(identity_dir, ["add", "-A", "--" | relative_paths])
    git!(identity_dir, ["commit", "--allow-empty", "-m", message], author)
  end

  defp git!(identity_dir, args, author \\ nil) do
    env =
      if author do
        email_local = String.replace(author, ~r/[^A-Za-z0-9_.+-]/, "-")

        [
          {"GIT_AUTHOR_NAME", author},
          {"GIT_AUTHOR_EMAIL", "#{email_local}@tightbeam.local"},
          {"GIT_COMMITTER_NAME", author},
          {"GIT_COMMITTER_EMAIL", "#{email_local}@tightbeam.local"}
        ]
      else
        []
      end

    case System.cmd("git", args, cd: identity_dir, stderr_to_stdout: true, env: env) do
      {_output, 0} -> :ok
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end

  defp validate!(manifest, path) do
    allowed =
      MapSet.new([
        "name",
        "skills",
        "where",
        "defaults",
        "references",
        "fallback_models",
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
    skills = Map.get(manifest, "skills", builtin_skill_names())

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

    mcp = validate_mcp!(Map.get(manifest, "mcp", %{}))
    containment = validate_containment!(Map.get(manifest, "containment", %{}), path)

    %{
      name: name,
      skills: skills,
      where: where,
      fallback_models: fallback_models,
      containment: containment,
      defaults: defaults,
      references: references,
      mcp: mcp,
      guidance: get_in(manifest, ["guidance", "text"])
    }
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

    unless fs in ["off", "workdir"] do
      raise ArgumentError, "archetype containment.fs must be off or workdir: #{path}"
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
