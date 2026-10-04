defmodule Tightbeam.FeatureSmokeTopology do
  @moduledoc false

  # The driver chooses a bounded disposable-fixture plan, then records it through
  # the same public coordination and holder-authenticated verdict seams as a CLI.
  # This is fixture setup, not a claim that a provider returned topology advice.
  # Callbacks must raise on wire errors; no DB writes or rule overrides live here.
  def prepare!(call, call_as, work_item_id, coordinator, plan, owner \\ nil) do
    key = get_in(coordinator, ["stream", "sessionKey"]) || coordinator["sessionKey"]

    assignment =
      call.("assign", %{
        "sessionKey" => key,
        "workItemId" => work_item_id,
        "effectKind" => "coordination",
        "subject" => "Coordinate disposable smoke fixture: " <> plan
      })

    call.("work-item-update", %{
      "workItemId" => work_item_id,
      "deliveryOwnerSessionKey" => owner || key
    })

    call_as.(key, "attest", %{
      "assignmentId" => assignment["id"] || assignment["assignmentId"],
      "kind" => "verdict",
      "verdictKind" => "topology-decided",
      "note" =>
        "Scripted disposable-fixture topology, not a provider consultation: " <>
          plan <>
          ". Keep product rules loaded; retain the assignment/dispatch assertions and " <>
          "retire only this fixture's sessions after its checks."
    })

    call_as.(key, "attest", %{
      "assignmentId" => assignment["id"] || assignment["assignmentId"],
      "kind" => "verdict",
      "verdictKind" => "posture-light",
      "note" =>
        "Scripted disposable-fixture posture: the existing smoke assertions are the bounded " <>
          "specification; one fixture holder and one linked review where completion requires it. " <>
          "No product implementation, provider judgment, or production acceptance is claimed."
    })
  end

  def review_check!(check) do
    # The only reviewed deliverable is the driver-created shell fixture. Refuse
    # any replacement, then independently execute and compare the observed bytes.
    source = File.read!(check.path)
    unless source == check.source, do: raise("smoke review: fixture source changed")
    [%{"commit" => commit}] = check.commit_refs

    {committed, 0} =
      System.cmd("git", ["show", "#{commit}:#{check.name}"], cd: Path.dirname(check.path))

    unless committed == source, do: raise("smoke review: source differs from the named commit")

    {output, status} =
      System.cmd("sh", [check.name], cd: Path.dirname(check.path), stderr_to_stdout: true)

    unless status == 0 and output == check.output,
      do: raise("smoke review: fixture execution disagrees with its passing receipt")

    hash = :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)

    "Operator-scripted review of disposable fixture #{check.name}, SHA256 #{hash}: " <>
      "source matches the seeded check; rerun exited 0 with exact output #{inspect(output)}. " <>
      "Filed on the linked review holder credential; no provider review or product acceptance claimed."
  end
end
