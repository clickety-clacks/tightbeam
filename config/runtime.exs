import Config

if config_env() != :test do
  if value = System.get_env("TIGHTBEAM_BASE_DIR") do
    config :tightbeam, :base_dir, value
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

  if value = System.get_env("TIGHTBEAM_PROD_LIMIT") do
    config :tightbeam, :prod_limit, String.to_integer(value)
  end

  if value = System.get_env("TIGHTBEAM_ESCALATION_DECISION_DEADLINE_MS") do
    config :tightbeam, :escalation_decision_deadline_ms, String.to_integer(value)
  end

  if value = System.get_env("TIGHTBEAM_EFFORT_CHECKIN_HORIZON_MS") do
    config :tightbeam, :effort_checkin_horizon_ms, String.to_integer(value)
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

  if value = System.get_env("TIGHTBEAM_LOCAL_HOST_NAME") do
    config :tightbeam, :local_host_name, value
  end
end
