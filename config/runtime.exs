import Config

if config_env() != :test do
  case System.get_env("TIGHTBEAM_EXECUTION_MAP_TURN_BACKFILL") do
    nil -> :ok
    "true" -> config :tightbeam, :execution_map_turn_backfill_enabled, true
    "false" -> config :tightbeam, :execution_map_turn_backfill_enabled, false
    _ -> raise ArgumentError, "TIGHTBEAM_EXECUTION_MAP_TURN_BACKFILL must be true or false"
  end

  case System.get_env("TIGHTBEAM_COORDINATOR_HOLD_DECISIONS") do
    nil -> :ok
    "true" -> config :tightbeam, :coordinator_hold_decisions_enabled, true
    "false" -> config :tightbeam, :coordinator_hold_decisions_enabled, false
    _ -> raise ArgumentError, "TIGHTBEAM_COORDINATOR_HOLD_DECISIONS must be true or false"
  end

  case System.get_env("TIGHTBEAM_PEOPLE_MESSAGING") do
    nil -> :ok
    "true" -> config :tightbeam, :people_messaging_enabled, true
    "false" -> config :tightbeam, :people_messaging_enabled, false
    _ -> raise ArgumentError, "TIGHTBEAM_PEOPLE_MESSAGING must be true or false"
  end

  if relay = System.get_env("TIGHTBEAM_PEOPLE_MESSAGE_RELAY_SESSION") do
    config :tightbeam, :people_message_relay_session, relay
  end

  case System.get_env("TIGHTBEAM_HARKLIGHT_PENDING_OPEN_ENABLED") do
    nil -> :ok
    "true" -> config :tightbeam, :harklight_pending_open_enabled, true
    "false" -> config :tightbeam, :harklight_pending_open_enabled, false
    _ -> raise ArgumentError, "TIGHTBEAM_HARKLIGHT_PENDING_OPEN_ENABLED must be true or false"
  end

  if value = System.get_env("TIGHTBEAM_BASE_DIR") do
    config :tightbeam, :base_dir, value
  end

  # An operator may carry the exact serialized build transition into the
  # packaged gateway. Keep the bytes untouched here: LiveBaseAdmission owns
  # strict decoding, base/source/target matching, and schema qualification.
  if value = System.get_env("TIGHTBEAM_LIVE_BASE_TRANSITION") do
    config :tightbeam, :live_base_guard, transition: value
  end

  if value = System.get_env("TIGHTBEAM_PORT") do
    config :tightbeam, :port, String.to_integer(value)
  end

  if value = System.get_env("TIGHTBEAM_CWD") do
    config :tightbeam, :cwd, value
  end

  if value =
       System.get_env("TIGHTBEAM_CREDENTIALS_DIRECTORY") ||
         System.get_env("CREDENTIALS_DIRECTORY") do
    config :tightbeam, :credentials_directory, value
  end

  if value = System.get_env("TIGHTBEAM_DEFAULT_HARNESS") do
    config :tightbeam, :default_harness, Tightbeam.Harness.parse!(value).id()
  end

  # The default selection is FIELDS, not one packed string: a packed default is one
  # vendor collision away from reading a context variant as a reasoning level.
  if value = System.get_env("TIGHTBEAM_DEFAULT_MODEL") do
    config :tightbeam,
           :default_model,
           Tightbeam.Model.new(value,
             effort: System.get_env("TIGHTBEAM_DEFAULT_EFFORT"),
             context: System.get_env("TIGHTBEAM_DEFAULT_CONTEXT")
           )
  end

  if value = System.get_env("TIGHTBEAM_WAKE_TICK_MS") do
    config :tightbeam, :wake_tick_ms, String.to_integer(value)
  end

  if value = System.get_env("TIGHTBEAM_HOLDER_PROD_HOURLY_CAP") do
    case Integer.parse(value) do
      {cap, ""} when cap > 0 -> config :tightbeam, :holder_prod_hourly_cap, cap
      _ -> raise ArgumentError, "TIGHTBEAM_HOLDER_PROD_HOURLY_CAP must be a positive integer"
    end
  end

  case System.get_env("TIGHTBEAM_HOLDER_PROD_REPORT_ONLY") do
    nil -> :ok
    "false" -> :ok
    "true" -> config :tightbeam, :holder_prod_report_only, true
    _ -> raise ArgumentError, "TIGHTBEAM_HOLDER_PROD_REPORT_ONLY must be true or false"
  end

  if value = System.get_env("TIGHTBEAM_PROD_LIMIT") do
    config :tightbeam, :prod_limit, String.to_integer(value)
  end

  if value = System.get_env("TIGHTBEAM_ESCALATION_DECISION_DEADLINE_MS") do
    config :tightbeam, :escalation_decision_deadline_ms, String.to_integer(value)
  end

  if value = System.get_env("TIGHTBEAM_WORK_ITEM_TRIAGE_DEADLINE_MS") do
    config :tightbeam, :work_item_triage_deadline_ms, String.to_integer(value)
  end

  if value = System.get_env("TIGHTBEAM_ADVERTISED_URL") do
    config :tightbeam, :advertised_url, value
  end

  # Hosts are registered in the database by `tightbeam assimilate`.

  if value = System.get_env("TIGHTBEAM_DRAIN_TIMEOUT_MS") do
    config :tightbeam, :drain_timeout_ms, String.to_integer(value)
  end

  if value = System.get_env("TIGHTBEAM_ARCHIVE_DIR") do
    config :tightbeam, :archive_dir, value
  end

  for {variable, key} <- [
        {"TIGHTBEAM_WORKSPACE_ARCHIVE_MAX_ENTRIES", :workspace_archive_max_entries},
        {"TIGHTBEAM_WORKSPACE_ARCHIVE_MAX_BYTES", :workspace_archive_max_bytes},
        {"TIGHTBEAM_WORKSPACE_ARCHIVE_RESERVE_BYTES", :workspace_archive_reserve_bytes},
        {"TIGHTBEAM_WORKSPACE_ARCHIVE_RESERVE_PERCENT", :workspace_archive_reserve_percent},
        {"TIGHTBEAM_WORKSPACE_CLEANUP_STUCK_ATTEMPTS", :workspace_cleanup_stuck_attempts}
      ],
      value = System.get_env(variable) do
    config :tightbeam, key, String.to_integer(value)
  end

  if value = System.get_env("TIGHTBEAM_ARTIFACT_ARCHIVE_INLINE_LIMIT_BYTES") do
    config :tightbeam, :artifact_archive_inline_limit_bytes, String.to_integer(value)
  end

  if root = System.get_env("TIGHTBEAM_ARTIFACT_BLOB_ROOT") do
    config :tightbeam, :artifact_blob_root, root
  end

  for {var, key} <- [
        {"TIGHTBEAM_ARTIFACT_BLOB_BUDGET_BYTES", :artifact_blob_budget_bytes},
        {"TIGHTBEAM_ARTIFACT_BLOB_FREE_FLOOR_BYTES", :artifact_blob_free_floor_bytes},
        {"TIGHTBEAM_ARTIFACT_BLOB_FREE_FLOOR_PERCENT", :artifact_blob_free_floor_percent}
      ],
      value = System.get_env(var) do
    config :tightbeam, key, String.to_integer(value)
  end

  if value = System.get_env("TIGHTBEAM_DB_CALL_TIMEOUT_MS") do
    config :tightbeam, :db_call_timeout_ms, String.to_integer(value)
  end

  if value = System.get_env("TIGHTBEAM_LOCAL_HOST_NAME") do
    config :tightbeam, :local_host_name, value
  end
end
