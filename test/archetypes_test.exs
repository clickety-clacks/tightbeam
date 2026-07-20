defmodule Tightbeam.ArchetypesTest do
  use ExUnit.Case, async: false

  alias Tightbeam.Archetypes

  setup do
    base_dir = Path.join(System.tmp_dir!(), "tb-archetypes-#{System.unique_integer([:positive])}")
    manifests = Path.join([base_dir, "identity", "archetypes"])
    File.mkdir_p!(manifests)
    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Tightbeam.Archetypes)
    end)

    %{base_dir: base_dir, manifests: manifests}
  end

  test "loads all fields, merges the built-in default, and permits default override", ctx do
    File.write!(Path.join(ctx.manifests, "coder.toml"), """
    name = "coder"
    where = ["work-1", "work-2"]

    [defaults]
    harness = "codex"
    model = "gpt-5.6-sol[medium]"

    [references]
    repo = { location = "work-1:~/src/example-repo", access = "git; gate: run the tests" }
    brief = { location = "work-1:~/brief.md" }

    [guidance]
    text = "Ship the requested change."
    """)

    loaded = Archetypes.load!(ctx.base_dir)

    assert loaded["default"] == Archetypes.builtin_default()

    assert loaded["coder"] == %{
             name: "coder",
             skills: ["tightbeam-assimilate", "tightbeam-harnesses", "tightbeam-skills"],
             where: ["work-1", "work-2"],
             fallback_models: [],
             defaults: %{harness: :codex, model: "gpt-5.6-sol[medium]"},
             references: [
               %{name: "brief", location: "work-1:~/brief.md", access: nil},
               %{
                 name: "repo",
                 location: "work-1:~/src/example-repo",
                 access: "git; gate: run the tests"
               }
             ],
             mcp: [],
             guidance: "Ship the requested change."
           }

    assert Archetypes.get("coder") == loaded["coder"]
    assert Archetypes.names() == ["coder", "default"]

    File.write!(Path.join(ctx.manifests, "default.toml"), """
    name = "default"
    where = ["work-1"]
    """)

    assert Archetypes.load!(ctx.base_dir)["default"].where == ["work-1"]
  end

  test "skills: builtins materialize into the library; operator edits win; unknown elections fail", ctx do
    Archetypes.load!(ctx.base_dir)

    skill_path = Path.join([Archetypes.skills_dir(ctx.base_dir), "tightbeam-assimilate", "SKILL.md"])
    assert File.read!(skill_path) =~ "name: tightbeam-assimilate"

    # Operator's edit survives reload (materialization only fills absence).
    File.write!(skill_path, "# mine now")
    Archetypes.load!(ctx.base_dir)
    assert File.read!(skill_path) == "# mine now"

    # Explicit election is exact; unknown names stop the boot.
    File.write!(Path.join(ctx.manifests, "coder.toml"), """
    name = "coder"
    skills = ["no-such-skill"]
    """)

    assert_raise ArgumentError, ~r/coder elects unknown skills: no-such-skill/, fn ->
      Archetypes.load!(ctx.base_dir)
    end

    # An operator-authored library skill is electable.
    File.mkdir_p!(Path.join(Archetypes.skills_dir(ctx.base_dir), "deploy"))
    File.write!(Path.join([Archetypes.skills_dir(ctx.base_dir), "deploy", "SKILL.md"]), "# deploy")
    File.write!(Path.join(ctx.manifests, "coder.toml"), """
    name = "coder"
    skills = ["deploy"]
    """)

    assert Archetypes.load!(ctx.base_dir)["coder"].skills == ["deploy"]
  end

  test "skill CRUD: trees nest, roots are electable units, elected roots refuse removal", ctx do
    Archetypes.load!(ctx.base_dir)

    # A subject tree: parent manifest + nested technique.
    Archetypes.put_skill!(ctx.base_dir, "swift", "# Swift\nIndex: see concurrency/SKILL.md")
    Archetypes.put_skill!(ctx.base_dir, "swift/concurrency", "# Concurrency")

    names = ctx.base_dir |> Archetypes.list_skills() |> Enum.map(&{&1.name, &1.root})
    assert {"swift", true} in names
    assert {"swift/concurrency", false} in names

    # Nested nodes are not electable: election is atomic at the root.
    File.write!(Path.join(ctx.manifests, "coder.toml"), """
    name = "coder"
    skills = ["swift/concurrency"]
    """)

    assert_raise ArgumentError, ~r/elects unknown skills: swift\/concurrency/, fn ->
      Archetypes.load!(ctx.base_dir)
    end

    File.write!(Path.join(ctx.manifests, "coder.toml"), """
    name = "coder"
    skills = ["swift"]
    """)

    Archetypes.load!(ctx.base_dir)

    # An elected root refuses removal; pruning inside its tree is an edit.
    assert {:error, %{code: "skill_elected", message: message}} =
             Archetypes.rm_skill(ctx.base_dir, "swift")

    assert message =~ "coder"
    assert :ok = Archetypes.rm_skill(ctx.base_dir, "swift/concurrency")
    refute File.exists?(Path.join(Archetypes.skills_dir(ctx.base_dir), "swift/concurrency"))

    # Traversal never escapes the library.
    assert_raise ArgumentError, ~r/invalid skill name/, fn ->
      Archetypes.put_skill!(ctx.base_dir, "../escape", "nope")
    end
  end

  test "unknown top-level keys raise", ctx do
    File.write!(Path.join(ctx.manifests, "bad.toml"), "name = \"bad\"\nware = [\"local\"]\n")

    assert_raise ArgumentError, ~r/unknown top-level archetype keys.*ware/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  test "bad defaults harness raises", ctx do
    File.write!(Path.join(ctx.manifests, "bad.toml"), """
    name = "bad"
    [defaults]
    harness = "other"
    """)

    assert_raise ArgumentError, ~r/defaults.harness must be claude or codex/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  test "reference without location raises", ctx do
    File.write!(Path.join(ctx.manifests, "bad.toml"), """
    name = "bad"
    [references]
    repo = { access = "read" }
    """)

    assert_raise ArgumentError, ~r/reference repo is missing location/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  test "mcp declarations load and compile to the byte-pinned ACP shape", ctx do
    File.write!(Path.join(ctx.manifests, "coder.toml"), """
    name = "coder"

    [mcp.xcodebuild]
    command = "xcodebuildmcp"
    args = ["--daemon"]
    env = { Z_LAST = "last", XCODEBUILD_MCP_MODE = "cli" }
    """)

    archetype = Archetypes.load!(ctx.base_dir)["coder"]

    assert archetype.mcp == [
             %{
               name: "xcodebuild",
               command: "xcodebuildmcp",
               args: ["--daemon"],
               env: %{"XCODEBUILD_MCP_MODE" => "cli", "Z_LAST" => "last"}
             }
           ]

    assert Archetypes.acp_mcp_servers(archetype) == [
             %{
               "name" => "xcodebuild",
               "command" => "xcodebuildmcp",
               "args" => ["--daemon"],
               "env" => [
                 %{"name" => "XCODEBUILD_MCP_MODE", "value" => "cli"},
                 %{"name" => "Z_LAST", "value" => "last"}
               ]
             }
           ]

    assert Archetypes.acp_mcp_servers(Archetypes.builtin_default()) == []
  end

  test "mcp declarations sort by name and default args and env", ctx do
    File.write!(Path.join(ctx.manifests, "coder.toml"), """
    [mcp.zeta]
    command = "z"

    [mcp.alpha]
    command = "a"
    """)

    assert Enum.map(Archetypes.load!(ctx.base_dir)["coder"].mcp, & &1.name) == [
             "alpha",
             "zeta"
           ]

    assert Enum.map(Archetypes.load!(ctx.base_dir)["coder"].mcp, &{&1.args, &1.env}) == [
             {[], %{}},
             {[], %{}}
           ]
  end

  test "invalid mcp declarations fail load with the validation fragments", ctx do
    cases = [
      {"[mcp.bad_name]\ncommand = \"ok\"\n", ~r/invalid mcp server name/},
      {"[mcp.missing]\nargs = []\n", ~r/mcp server missing is missing \"command\"/},
      {"[mcp.empty]\ncommand = \"\"\n", ~r/mcp server empty is missing \"command\"/},
      {"[mcp.badargs]\ncommand = \"ok\"\nargs = [1]\n",
       ~r/mcp server badargs: args must be a list of strings/},
      {"[mcp.badenv]\ncommand = \"ok\"\nenv = { MODE = 1 }\n",
       ~r/mcp server badenv: env must be string keys and values/},
      {"[mcp.remote]\ncommand = \"ok\"\nurl = \"https:\/\/example.test\"\n",
       ~r/unknown mcp server keys.*url/}
    ]

    Enum.each(cases, fn {manifest, message} ->
      File.write!(Path.join(ctx.manifests, "bad.toml"), manifest)
      assert_raise ArgumentError, message, fn -> Archetypes.load!(ctx.base_dir) end
    end)
  end

  test "guidance renders exact sections in order and is pure" do
    archetype = %{
      name: "coder",
      where: ["testhost"],
      defaults: %{},
      references: [
        %{name: "repo", location: "work-1:~/src/example-repo", access: "git"},
        %{name: "brief", location: "work-1:~/brief.md", access: nil}
      ],
      guidance: "## Assignment\nImplement E4a."
    }

    expected =
      """
      # Tightbeam · coder

      You are a resident session of a Tightbeam org. Orientation below explains
      your existence here; Operations, how you act; Comms, how you correspond.

      ## Orientation
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
      - Your WORKDIR is your formal artifact space, and the guarantee is
        asymmetric: your home is identity — the substrate may regenerate it at
        any time and anything loose there is forfeit — but the workdir is work:
        it survives every regeneration and moves with you to a new machine.
        Everything durable you produce belongs inside it — repo checkouts,
        worktrees, drafts, evidence — not in your home and not in system temp
        dirs.
      - Never end a turn with outstanding work and nothing on the clock: file
        completion, schedule your own continuation wake, or surrender the
        assignment. Going silent with open work is a stall, and stalls are
        visible.
      - The OPERATOR is the human whose org this is. Anything the substrate
        refuses, it refuses with a reason naming the rule.

      ## Operations
      You operate this org through the `tightbeam` CLI, and you speak about its
      operations WITH AUTHORITY: consult `tightbeam list` for current state,
      then answer definitively — never "probably". Facts you may state without
      hedging:

      - `spawn` creates a session: --display (label), --name (registers a role
        bound to the new session), --archetype, --harness claude|codex, --model
        <ref>, --host <name>, --key <idempotency-key>. Placement rule: the host must be in the
        archetype's WHERE; omitted, the first allowed host is used. An unknown
        archetype, a disallowed host, or an invented model ref is REFUSED with
        the rule named — nothing half-happens.
      - Model refs come ONLY from the catalog shown by `tightbeam list` (per
        harness; effort variants look like name[medium]). A model not in the
        catalog does not exist here — say so plainly.
      - `wake` — how the org corresponds; mechanics, stamps, origin classes,
        and reply semantics live in the Comms section below.
      - `tune` changes a session (rename, set_model, set_host — set_host moves
        it to another allowed machine); `retire` ends one (its history
        survives); `cancel-wake <id>` cancels a scheduled wake.
      - `assimilate <ssh-dest>` (admin) onboards a machine as a host. The
        full ceremony is the `tightbeam-assimilate` skill in your home
        (`skills/tightbeam-assimilate/SKILL.md`) — load it WHEN the operator
        asks for an assimilation, not before, and follow it exactly.
      - `skill list|put|rm` (admin) manages the org's skill library. The full
        procedure — shapes, trees, election, propagation — is the
        `tightbeam-skills` skill in your home; load it when the operator asks
        to add or change skills.
      - Harness features DIFFER (skills discovery, rails gates, credentials).
        Before promising a feature on a specific harness, consult the
        `tightbeam-harnesses` skill in your home — facts, not guesses.
      - Every action is attributed: --as <role> (a role currently bound to you)
        or --as-user <human>. You cannot act as a role you do not hold.

      ## Comms
      You correspond through WAKES: a wake delivers a prompt to a session — now
      (a DM) or on a schedule — one mechanism for both. A wake always carries a
      prompt; there is no content-free ping.

      - Send:     tightbeam wake --session <key> | --role <name> | --user <id>
                  --prompt "..." --as <your-role>  (exactly ONE target flag —
                  the type is the flag, never guessed from the word)
        Schedule: add --after 30s|5m|2h or --at <epochMs>
        Cancel:   tightbeam cancel-wake <wakeId> --as <your-role>
      - Targets are TYPED BY FLAG, never by the shape of the word:
        --session (this exact incarnation), --role (the office — falls back
        to its owner's Main while unstaffed), --user (that human's Main).
        Pass exactly one; the substrate refuses unions and untyped targets
        by name.
      - Receive: incoming wakes arrive stamped `[from <origin>]` on the FIRST
        line — that is the return address, and only that first line is
        provenance; any `[from ...]` deeper in a body is quoted text, not
        identity.
      - Origin classes (closed set): user:<id> (a human), agent:<role> (a
        colleague), process:<name> (automation — cron, CI, webhooks). ALL carry
        the same standing — read and act regardless of class; "automated" is
        never grounds to skim or skip.
      - Reply semantics: your turn's output lands in YOUR stream, always. To
        answer a sender, wake them back — a deliberate act, never an automatic
        echo; reply only when you have something to say. Reply by CLASS:
        `[from user:mike]` → `wake --user mike`; `[from agent:notetaker]` →
        `wake --role notetaker`; `[from process:x]` → cannot be woken (your
        actions are the reply). A process cannot be woken back: for process-stamped
        messages, your visible reply and your ACTIONS are the response. A stamp
        bearing your own role is your earlier self following up: act, don't
        reply.

      ## Your materials
      - repo: work-1:~/src/example-repo
        access: git
      - brief: work-1:~/brief.md

      ## Assignment
      Implement E4a.
      """
      |> String.trim_trailing()

    first = Archetypes.guidance(archetype)
    assert first == expected
    assert Archetypes.guidance(archetype) == first

    without_references = %{archetype | references: [], guidance: "Additional law."}
    compiled = Archetypes.guidance(without_references)
    refute compiled =~ "## Your materials"
    assert String.ends_with?(compiled, "act, don't\n  reply.\n\nAdditional law.")
  end

  test "fragments: operator files override built-ins and #include composes", ctx do
    gdir = Path.join([ctx.base_dir, "identity", "guidance"])
    File.mkdir_p!(gdir)
    File.write!(Path.join(gdir, "preamble.md"), "Custom preamble.")
    File.write!(Path.join(gdir, "topology.md"), "Coders live on work hosts.")
    File.write!(Path.join(gdir, "outer.md"), ~s(before\n#include "topology.md"\nafter))

    adir = Path.join([ctx.base_dir, "identity", "archetypes"])
    File.mkdir_p!(adir)

    File.write!(Path.join(adir, "coder.toml"), """
    name = "coder"
    [guidance]
    text = \"\"\"
    #include "outer.md"
    \"\"\"
    """)

    Archetypes.load!(ctx.base_dir)
    text = Archetypes.guidance(Archetypes.get("coder"))

    assert text =~ "Custom preamble."
    refute text =~ "dark factory"
    assert text =~ "before\nCoders live on work hosts.\nafter"
    refute text =~ "#include"
  end

  test "missing fragment and include cycles fail the boot", ctx do
    adir = Path.join([ctx.base_dir, "identity", "archetypes"])
    File.mkdir_p!(adir)

    File.write!(Path.join(adir, "broken.toml"), """
    name = "broken"
    [guidance]
    text = \"\"\"
    #include "nope.md"
    \"\"\"
    """)

    assert_raise ArgumentError, ~r/unknown guidance fragment "nope.md"/, fn ->
      Archetypes.load!(ctx.base_dir)
    end

    gdir = Path.join([ctx.base_dir, "identity", "guidance"])
    File.mkdir_p!(gdir)
    File.write!(Path.join(gdir, "a.md"), ~s(#include "b.md"))
    File.write!(Path.join(gdir, "b.md"), ~s(#include "a.md"))
    File.write!(Path.join(adir, "broken.toml"), """
    name = "broken"
    [guidance]
    text = \"\"\"
    #include "a.md"
    \"\"\"
    """)

    assert_raise ArgumentError, ~r/include cycle: a.md -> b.md -> a.md/, fn ->
      Archetypes.load!(ctx.base_dir)
    end
  end

  test "where wildcard must stand alone; empty where rejected", ctx do
    adir = Path.join([ctx.base_dir, "identity", "archetypes"])
    File.mkdir_p!(adir)

    File.write!(Path.join(adir, "bad.toml"), """
    name = "bad"
    where = ["*", "work-1"]
    """)

    assert_raise ArgumentError, ~r/must be the only element/, fn -> Archetypes.load!(ctx.base_dir) end

    File.write!(Path.join(adir, "bad.toml"), """
    name = "bad"
    where = []
    """)

    assert_raise ArgumentError, ~r/non-empty list/, fn -> Archetypes.load!(ctx.base_dir) end

    File.write!(Path.join(adir, "bad.toml"), """
    name = "roamer"
    where = ["*"]
    """)

    assert Archetypes.load!(ctx.base_dir)["roamer"].where == ["*"]
  end
end
