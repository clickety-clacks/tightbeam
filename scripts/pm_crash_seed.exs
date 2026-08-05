# SMOKE §11 step 43, phase 1 (see scripts/pm_crash_smoke.sh — the orchestrator
# that runs this, kills the VM mid-turn, and reboots): boot the application,
# onboard anthropic from stdin-provided key path, spawn a credentialed lineage,
# start a LONG live turn in the child, then hold the VM open to be killed.

defmodule Pm43 do
  def await(fun, label, tries \\ 240) do
    case fun.() do
      {:ok, value} -> value
      :retry when tries > 0 ->
        Process.sleep(500)
        await(fun, label, tries - 1)
      other -> raise("43 TIMEOUT #{label}: last #{inspect(other)}")
    end
  end
end

alias Tightbeam.{DB, Gateway, Model, Org}

{:ok, _} = Application.ensure_all_started(:tightbeam)
db = Tightbeam.DB
base = System.get_env("TIGHTBEAM_BASE_DIR")
IO.puts("43 seed: application started, base=#{base}")

{:ok, _} = DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

mk = fn key, spawned_by, built_in ->
  Org.create(db, %{
    session_key: key,
    display_name: key,
    owner_user_id: "flynn",
    origin: "user:flynn",
    archetype: "default",
    harness: "claude",
    provider: "anthropic",
    host: Tightbeam.Placement.local_host_name(),
    model: Model.new("sonnet", effort: "medium"),
    spawned_by: spawned_by,
    is_built_in: built_in
  })
end

main = mk.(Org.personal_session_key("flynn"), nil, true)
_parent = mk.("s43:parent", main.session_key, false)
_child = mk.("s43:child", "s43:parent", false)

cli = Path.expand("cli/target/release/tightbeam")

{_, 0} =
  System.cmd(
    "sh",
    ["-c", "cat $HOME/tb-test-keys/anthropic | #{cli} onboard anthropic --api-key --as-user flynn"],
    env: [{"TIGHTBEAM_BASE_DIR", base}],
    stderr_to_stdout: true
  )

Pm43.await(
  fn -> if Tightbeam.Credentials.status(:anthropic) == :onboarded, do: {:ok, true}, else: :retry end,
  "credential banked",
  60
)

IO.puts("43 seed: anthropic onboarded")

:appended =
  Gateway.deliver_prompt(
    "s43:child",
    "user:flynn",
    "Without using any tools, write a very long and thorough essay (at least " <>
      "2000 words) on the history of telephone switchboards and patchbays. " <>
      "Take your time and be exhaustive.",
    db: db
  )

Pm43.await(
  fn ->
    case DB.query(db, "SELECT status FROM turns WHERE sessionKey='s43:child'") do
      {:ok, [["running"]]} -> {:ok, true}
      _ -> :retry
    end
  end,
  "child turn RUNNING (live claude mid-answer)"
)

IO.puts("43 seed: RUNNING — kill me now")
Process.sleep(:infinity)
