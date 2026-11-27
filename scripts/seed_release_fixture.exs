# Evaluated by the release package after its normal application startup.
alias Tightbeam.{Artifacts, Assignments, Devices, Escalation, Model, Org, Wakes, WorkItems}

owner = "fixture"
Devices.add_user(owner, true)

[opener, holder] =
  for role <- ["opener", "holder"] do
    Org.create(%{
      session_key: "agent:fixture:#{role}",
      display_name: "Fixture #{role}",
      owner_user_id: owner,
      origin: "user:#{owner}",
      host: Tightbeam.Placement.local_host_name(),
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-sonnet-5", effort: "medium"),
      archetype: "default"
    }).session_key
  end

call = fn verb, caller, params ->
  %{
    verb: verb,
    origin: caller,
    principal: {:session, caller},
    transport_session_key: caller,
    session_key: nil,
    target_role: nil,
    role_fallback: false,
    supervision_interval_ms: 1_000,
    params: params
  }
end

%{id: work} =
  WorkItems.__handle__(
    Tightbeam.DB,
    "work-item-create",
    call.("work-item-create", opener, %{title: "Fixture work"})
  )

%{id: assignment} =
  Assignments.__handle__(
    Tightbeam.DB,
    "assign",
    %{call.("assign", opener, %{subject: "Fixture task", work_item_id: work, effect_kind: "coordination"}) |
      session_key: holder}
  )

%{attest: %{id: _}} =
  Assignments.__handle__(
    Tightbeam.DB,
    "attest",
    call.("attest", holder, %{assignment_id: assignment, kind: "progress", note: "Fixture progress"})
  )

%{artifact_id: _} =
  Artifacts.record(%{call.("artifact-record", holder, %{
    work_item_id: work,
    kind: "report",
    title: "Fixture artifact",
    origin_path: "/fixture/report.txt",
    allow_unpinned: true
  }) | session_key: holder})

%{id: _} =
  Escalation.operator_ask(call.("operator-ask", holder, %{
    question: "Continue fixture work?",
    project: "Fixture",
    assignment_id: assignment
  }))

%{wake_id: _} =
  Wakes.schedule(%{
    session_key: holder,
    owner_user_id: owner,
    origin: opener,
    prompt: "Fixture wake",
    due_at: 4_102_444_800_000
  })
