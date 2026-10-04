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
  end
end
