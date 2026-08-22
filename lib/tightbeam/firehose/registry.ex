defmodule Tightbeam.Firehose.Registry do
  @moduledoc """
  The v1 class vocabulary and its state-resource mapping.

  Observational classes intentionally have no resource mapping. Admin-state
  classes are held out until the open projection ruling freezes their public
  resource bytes.
  """

  @observational ~w(
    verb.accepted verb.denied rail.denied lifecycle.boot lifecycle.clean_shutdown
    lifecycle.dirty_exit lifecycle.takeover
  )

  @state_rows [
    {"work_item.created", "work-items", "upsert", "workItemId"},
    {"work_item.updated", "work-items", "upsert", "workItemId"},
    {"work_item.iceboxed", "work-items", "upsert", "workItemId"},
    {"work_item.reopened", "work-items", "upsert", "workItemId"},
    {"work_item.closed", "work-items", "upsert", "workItemId"},
    {"work_item.failed", "work-items", "upsert", "workItemId"},
    {"assignment.opened", "assignments", "upsert", "assignmentId"},
    {"assignment.reopened", "assignments", "upsert", "assignmentId"},
    {"assignment.closed", "assignments", "upsert", "assignmentId"},
    {"attest.filed", "attests", "upsert", "attestId"},
    {"wake.scheduled", "wakes", "upsert", "wakeId"},
    {"wake.fired", "wakes", "upsert", "wakeId"},
    {"wake.canceled", "wakes", "upsert", "wakeId"},
    {"prod.fired", "productions", "upsert", "eventId"},
    {"turn.started", "turns", "upsert", "turnSeq"},
    {"turn.ended", "turns", "upsert", "turnSeq"},
    {"decision_request.opened", "decision-requests", "upsert", "decisionRequestId"},
    {"decision_request.ruled", "decision-requests", "upsert", "decisionRequestId"},
    {"decision_request.withdrawn", "decision-requests", "upsert", "decisionRequestId"},
    {"session.spawned", "sessions", "upsert", "sessionKey"},
    {"session.retired", "sessions", "upsert", "sessionKey"},
    {"role.created", "roles", "upsert", "role"},
    {"role.bound", "roles", "upsert", "role"},
    {"role.removed", "roles", "delete", "role"},
    {"user.added", "users", "upsert", "userId"},
    {"device.approved", "devices", "upsert", "deviceId"},
    {"device.denied", "devices", "upsert", "deviceId"},
    {"device.revoked", "devices", "upsert", "deviceId"},
    {"artifact.recorded", "artifacts", "upsert", "artifactId"},
    {"read_marker.updated", "read-markers", "upsert", "scopeKey"},
    {"message.created", "messages", "upsert", "messageId"},
    {"condition_fact.filed", "condition-facts", "upsert", "factId"},
    {"critical_lease.updated", "critical-state", "upsert", "sessionKey"}
  ]

  @serializers %{
    "work-items" => :work_item,
    "assignments" => :assignment,
    "attests" => :attest,
    "wakes" => :wake,
    "productions" => :production,
    "turns" => :turn,
    "decision-requests" => :decision_request,
    "sessions" => :session,
    "roles" => :role,
    "users" => :user,
    "devices" => :device,
    "artifacts" => :artifact,
    "read-markers" => :read_marker,
    "messages" => :message,
    "condition-facts" => :condition_fact,
    "critical-state" => :critical_state
  }

  @rows Map.new(@state_rows, fn {class, resource, op, primary_ref} ->
          {class,
           %{
             class: class,
             resource: resource,
             op: op,
             primary_ref: primary_ref,
             serializer: Map.fetch!(@serializers, resource),
             query: :query,
             visibility: :visible?
           }}
        end)

  @spec rows() :: %{String.t() => map()}
  def rows, do: @rows

  @spec observational_classes() :: [String.t()]
  def observational_classes, do: @observational

  @spec classes() :: [String.t()]
  def classes, do: Enum.sort(Map.keys(@rows) ++ @observational)

  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(class), do: Map.fetch(@rows, class)
end
