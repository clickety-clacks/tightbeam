defmodule Tightbeam.Firehose.Registry do
  @moduledoc """
  The v1 class vocabulary and its state-resource mapping.

  Observational classes intentionally have no resource mapping. Rows marked
  rebuildable name the shared query, serializer, visibility, primary refs, and
  durable version source used by rebuilds and notices.
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
    {"decision_request.returned", "decision-requests", "upsert", "decisionRequestId"},
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

  @admin_rows [
    %{
      class: "config.updated",
      resource: "config",
      op: "upsert",
      primary_refs: ["key"],
      query: :query_config,
      serializer: :config,
      visibility: :config_visible?,
      rebuild: true,
      version_source: "admin_projection_versions"
    },
    %{
      class: "host_env.updated",
      resource: "host environment",
      op: "upsert",
      primary_refs: ["host", "harness", "name"],
      query: :query_host_environment,
      serializer: :host_environment,
      visibility: :host_environment_visible?,
      rebuild: true,
      version_source: "admin_projection_versions+host_environment_projection"
    },
    %{
      class: "host.registered",
      resource: "hosts",
      op: "upsert",
      primary_refs: ["host"],
      query: :query_host,
      serializer: :host,
      visibility: :host_visible?,
      rebuild: true,
      version_source: "admin_projection_versions"
    },
    %{
      class: "user.promoted",
      resource: "users",
      op: "upsert",
      primary_refs: ["userId"],
      query: :query_user,
      serializer: :user,
      visibility: :user_visible?,
      rebuild: true,
      version_source: "admin_projection_versions"
    },
    %{
      class: "identity.updated",
      resource: "identity",
      op: "upsert",
      primary_refs: ["name"],
      query: :query_identity,
      serializer: :identity,
      visibility: :identity_visible?,
      rebuild: true,
      version_source: "admin_projection_versions.publication_stamp"
    },
    %{
      class: "kungfu.updated",
      resource: "kungfu",
      op: "upsert",
      primary_refs: ["name"],
      query: :query_kungfu,
      serializer: :kungfu,
      visibility: :kungfu_visible?,
      rebuild: true,
      version_source: "admin_projection_versions.publication_stamp"
    }
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
    "critical-state" => :critical_state,
    "config" => :config,
    "host environment" => :host_environment,
    "hosts" => :host,
    "identity" => :identity,
    "kungfu" => :kungfu
  }

  @rows @state_rows
        |> Map.new(fn {class, resource, op, primary_ref} ->
          {class,
           %{
             class: class,
             resource: resource,
             op: op,
             primary_ref: primary_ref,
             primary_refs: [primary_ref],
             serializer: Map.fetch!(@serializers, resource)
           }}
        end)
        |> Map.update!("user.added", fn row ->
          Map.merge(row, %{
            query: :query_user,
            visibility: :user_visible?,
            rebuild: true,
            version_source: "admin_projection_versions"
          })
        end)
        |> Map.update!("attest.filed", fn row ->
          Map.merge(row, %{
            query: :query_attest,
            visibility: :visible?,
            rebuild: true,
            version_source: "append_only"
          })
        end)
        |> Map.update!("condition_fact.filed", fn row ->
          Map.merge(row, %{
            query: :query_condition_fact,
            visibility: :visible?,
            rebuild: true,
            version_source: "append_only"
          })
        end)
        |> Map.update!("message.created", fn row ->
          row
          |> Map.merge(%{
            query: :query_message,
            visibility: :visible?,
            rebuild: true,
            version_source: "append_only"
          })
          |> Map.put(:primary_refs, ["messageId", "sessionKey"])
        end)
        |> Map.update!("prod.fired", fn row ->
          Map.merge(row, %{
            query: :query_production,
            visibility: :visible?,
            rebuild: true,
            version_source: "append_only"
          })
        end)
        |> Map.update!("critical_lease.updated", fn row ->
          Map.merge(row, %{
            query: :query_critical_state,
            visibility: :visible?,
            rebuild: true,
            version_source: "critical_lease.updated_at"
          })
        end)
        |> then(fn rows ->
          Enum.reduce(
            ~w(device.approved device.denied device.revoked),
            rows,
            fn class, rows ->
              Map.update!(rows, class, fn row ->
                Map.merge(row, %{
                  query: :query_device,
                  visibility: :visible?,
                  rebuild: true,
                  version_source: "device_versions"
                })
              end)
            end
          )
        end)
        |> Map.update!("read_marker.updated", fn row ->
          Map.merge(row, %{
            query: :query_read_marker,
            visibility: :visible?,
            rebuild: true,
            version_source: "read_marker.updated_at"
          })
        end)
        |> Map.merge(
          Map.new(@admin_rows, &{&1.class, Map.put(&1, :primary_ref, hd(&1.primary_refs))})
        )

  @spec rows() :: %{String.t() => map()}
  def rows, do: @rows

  @spec observational_classes() :: [String.t()]
  def observational_classes, do: @observational

  @spec classes() :: [String.t()]
  def classes, do: Enum.sort(Map.keys(@rows) ++ @observational)

  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(class), do: Map.fetch(@rows, class)
end
