defmodule Tightbeam.ShippedPolicyFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias Tightbeam.{Gateway, Identity, Org, Rules}

  # These tests exercise the shipped policy after its real activation boundary.
  # Stored caller stamps model supported materialization; they do not claim an
  # external adapter or model acknowledged the new guidance.
  def learn_engineering!(db, base, handlers, extra_rules \\ []) do
    config = %{db: db, base_dir: base}
    verbs = Map.keys(handlers)
    Gateway.load_law!(config, verbs)
    assert {:ok, candidate} = Identity.learn!(base, "agentic-engineering", "test")

    candidate =
      if extra_rules == [] do
        candidate
      else
        dir = Path.join(base, "identity")
        for {name, bytes} <- extra_rules, do: File.write!(Path.join(dir, "rules/" <> name), bytes)
        git!(dir, ["add", "rules"])
        git!(dir, ["commit", "-m", "additional test predicate"])

        %{candidate | candidate_revision: git!(dir, ["rev-parse", "HEAD"])}
        |> Map.delete(:tree_fingerprint)
      end

    assert {:ok, %{phase: :candidate_preflight}} =
             Gateway.preflight_candidate_law!(config, candidate, "test", verbs)

    assert {:ok, _} = Identity.publish_live!(base, candidate)
    Gateway.stage_published_law!(config, verbs)

    case Gateway.staged_cutover_state!(config) do
      {:error, %Tightbeam.Mementos.Refusal{details: %{sessions: sessions}}} ->
        for session <- sessions do
          Org.set_identity_stamp(
            db,
            session.session_key,
            candidate.candidate_revision,
            session.expected_render_contract,
            session.expected_guidance_digest
          )
        end

      {:ok, _} ->
        :ok
    end

    assert {:ok, %{state: "active"}} = Gateway.activate_staged_law!(config)

    snapshot = Rules.effective_snapshot()
    assert snapshot.revision == candidate.candidate_revision
    assert snapshot.requested_admission_contract == %{}
    assert Rules.active_admission_contract("attest") == "legacy"
    Rules.effective_snapshot().rules
  end

  defp git!(dir, args) do
    {output, status} =
      System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid"] ++ args,
        cd: dir,
        stderr_to_stdout: true
      )

    assert status == 0, output
    String.trim(output)
  end
end
