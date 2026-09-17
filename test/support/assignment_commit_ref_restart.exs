[payload, base, locks] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)

{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :local_host_name, "testhost")

import ExUnit.Assertions
alias Tightbeam.{AssignmentCommitRefCorrections, DB, Model, Schema}

db = :commitref_restart
path = Path.join(base, "state.db")
{:ok, first} = DB.start_link(path: path, name: db, guard_inputs: [lock_dir: locks])

try do
  :ok = Schema.ensure_all(db)

  :ok =
    DB.execute(db, """
    INSERT INTO users (userId, isAdmin, createdAt)
    VALUES ('owner', 0, 1), ('other', 0, 1);

    INSERT INTO sessions
      (sessionKey, displayName, ownerUserId, origin, spawnedBy, archetype,
       harness, provider, model, host, createdAt, updatedAt)
    VALUES
      ('po-owner', 'Product owner', 'owner', 'user:owner', NULL, 'product-owner',
       'fixture', 'fixture_provider', 'test', 'testhost', 1, 1),
      ('holder-owner', 'Holder', 'owner', 'session:po-owner', 'po-owner', 'coder',
       'fixture', 'fixture_provider', 'test', 'testhost', 1, 1),
      ('po-other', 'Other product owner', 'other', 'user:other', NULL, 'product-owner',
       'fixture', 'fixture_provider', 'test', 'testhost', 1, 1),
      ('holder-other', 'Other holder', 'other', 'session:po-other', 'po-other', 'coder',
       'fixture', 'fixture_provider', 'test', 'testhost', 1, 1);

    INSERT INTO work_items
      (id, title, ownerUserId, state, createdByUser, createdAt)
    VALUES
      ('wi_history', 'Historical correction', 'owner', 'open', 'owner', 1),
      ('wi_other', 'Other evidence', 'other', 'open', 'other', 1);

    INSERT INTO assignments
      (id, subject, holderKey, openedBySession, openedAt, state, workItemId)
    VALUES
      ('asg_closed', 'closed history', 'holder-owner', 'po-owner', 2, 'open', 'wi_history'),
      ('asg_hidden', 'other lane', 'holder-other', 'po-other', 2, 'open', 'wi_other');

    INSERT INTO assignment_revocations
      (id, assignmentId, revokedAt, revokedBySession, reason)
    VALUES
      ('rev_closed', 'asg_closed', 3, 'po-owner', 'historical revocation'),
      ('rev_hidden', 'asg_hidden', 3, 'po-other', 'historical revocation');

    INSERT INTO assignment_revocation_generations
      (revocationId, assignmentId, reopeningId)
    VALUES
      ('rev_closed', 'asg_closed', NULL),
      ('rev_hidden', 'asg_hidden', NULL);

    UPDATE assignments
    SET state='closed', outcome='revoked', closedAt=3, closedBySession='po-owner'
    WHERE id='asg_closed';

    UPDATE assignments
    SET state='closed', outcome='revoked', closedAt=3, closedBySession='po-other'
    WHERE id='asg_hidden';

    INSERT INTO artifacts
      (artifactId, kind, title, createdBySession, workItemId, originPath,
       contentSha256, state, createdAt, updatedAt)
    VALUES
      ('art_evidence', 'report', 'canonical proof', 'po-owner', 'wi_history',
       '/proof/history.md', '#{String.duplicate("a", 64)}', 'in-workspace', 4, 4);
    """)

  root = Path.join(Path.dirname(base), "commitref-restart-repo")
  repo = Path.join(root, "repo")
  remote = Path.join(root, "remote.git")
  File.mkdir_p!(root)

  git! = fn cwd, args ->
    {_output, 0} = System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)
    :ok
  end

  git_output! = fn cwd, args ->
    {output, 0} = System.cmd("git", ["-C", cwd | args], stderr_to_stdout: true)
    String.trim(output)
  end

  git!.(root, ["init", "--bare", remote])
  git!.(root, ["init", "-b", "main", repo])
  git!.(repo, ["config", "user.email", "test@example.invalid"])
  git!.(repo, ["config", "user.name", "Test"])
  File.write!(Path.join(repo, "proof.txt"), "canonical\n")
  git!.(repo, ["add", "proof.txt"])
  git!.(repo, ["commit", "-m", "canonical"])
  git!.(repo, ["remote", "add", "origin", remote])
  git!.(repo, ["push", "-u", "origin", "main"])
  commit = git_output!.(repo, ["rev-parse", "HEAD"])

  call = %{
    principal: {:session, "po-owner"},
    params: %{
      assignment_id: "asg_closed",
      commit_refs: [
        %{
          "repo" => "testhost:#{repo}",
          "remote" => remote,
          "ref" => "refs/heads/main",
          "commit" => commit
        }
      ],
      evidence_artifact_id: "art_evidence",
      reason: "canonical historical backfill",
      idempotency_key: "history-1"
    }
  }

  assert %{correction: first_correction} =
           AssignmentCommitRefCorrections.__handle__(db, "assignment-commitref-correct", call)

  :ok = GenServer.stop(first)
  {:ok, second} = DB.start_link(path: path, name: db, guard_inputs: [lock_dir: locks])

  try do
    :ok = Schema.ensure_all(db)
    assert [^first_correction] = AssignmentCommitRefCorrections.list(db, "asg_closed")

    assert %{correction: ^first_correction} =
             AssignmentCommitRefCorrections.__handle__(db, "assignment-commitref-correct", call)
  after
    :ok = GenServer.stop(second)
  end
after
  if Process.alive?(first), do: GenServer.stop(first)
end

IO.puts("commitref-restart: ok")
