#!/usr/bin/env elixir

# R41 executable reality-smoke. The coordinator supplies the disposable
# template and host; absence is a named blocker rather than a false pass.

defmodule WorkItemBodySmoke do
  alias Tightbeam.ClientE2E.LegGateway
  alias Tightbeam.{DB, Schema}

  @min_port 12_000
  @spec_ref "specs/smoke/work-item-body.md"
  @spec_sha String.duplicate("a", 64)
  @body "  Scope\n✓ \"ship\"\n"

  def run do
    template = required_env!("TIGHTBEAM_WORK_ITEM_BODY_SMOKE_TEMPLATE")
    port = required_env!("TIGHTBEAM_WORK_ITEM_BODY_SMOKE_PORT") |> port!()

    repo = File.cwd!()
    binary = Path.join(repo, "cli/target/release/tightbeam")

    {source_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo)
    source_head = String.trim(source_head)
    binary_sha = :crypto.hash(:sha256, File.read!(binary)) |> Base.encode16(case: :lower)

    base =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-client-e2e-work-item-body-#{System.os_time(:second)}-#{System.unique_integer([:positive])}"
      )

    require_dir!(template, "template")
    require_file!(binary, "built CLI")
    Process.put(:body_smoke_base, base)
    Process.put(:body_smoke_gateway, nil)

    try do
      IO.puts(
        "R41 phase=provision template=#{template} base=#{base} work=#{Path.join(base, "work")} port=#{port} binary=#{binary} source=#{source_head} binarySha256=#{binary_sha}"
      )

      LegGateway.provision!(template, base)
      File.mkdir_p!(Path.join(base, "work"))
      seed_disposable_state!(base)

      gateway =
        case LegGateway.boot(base, port, repo_root: repo) do
          {:ok, gateway} -> gateway
          {:error, reason, gateway} ->
            Process.put(:body_smoke_gateway, gateway)
            raise("R41 gateway boot failed: #{inspect(reason)}")
        end

      Process.put(:body_smoke_gateway, gateway)
      IO.puts("R41 gateway=booted pid=#{gateway.os_pid} port=#{gateway.port}")

      {item_id, smoke_user} = run_cli_scenario!(gateway, binary, source_head)

      case LegGateway.restart(gateway) do
        {:ok, restarted} ->
          Process.put(:body_smoke_gateway, restarted)
          IO.puts("R41 gateway=restart old_pid=#{gateway.os_pid} new_pid=#{restarted.os_pid}")

          run_restart_readback!(restarted, binary, item_id, smoke_user)

        {:error, {:restart_boot_failed, reason, failed_gateway}} ->
          Process.put(:body_smoke_gateway, failed_gateway)
          raise("R41 gateway restart failed: #{inspect(reason)} log=#{failed_gateway.log_path}")

        {:error, reason} ->
          raise("R41 gateway restart failed: #{inspect(reason)}")
      end
    after
      teardown!()
    end

    IO.puts("R41 verdict=pass")
  end

  defp run_cli_scenario!(gateway, binary, source_head) do
    env = cli_env(gateway)
    work_dir = Path.join(gateway.base_dir, "work")
    IO.puts("R41 phase=cli-scenario")
    {cli_version, 0} = System.cmd(binary, ["version"], cd: work_dir, env: env)
    IO.puts("R41 versions source=#{source_head} cli=#{String.trim(cli_version)}")

    smoke_user = "smoke-admin"
    run!(binary, ["add-user", smoke_user, "--admin"], work_dir, env)

    created =
      run_json!(
        binary,
        [
          "work-item-create",
          "--title",
          "R41 body smoke",
          "--spec-ref",
          @spec_ref,
          "--spec-sha256",
          @spec_sha,
          "--as-user",
          smoke_user
        ],
        work_dir,
        env
      )

    assert!(not Map.has_key?(created, "body"), "create response must be body-free")
    id = created["id"] || raise("R41 create returned no work-item id")

    legacy =
      run_json!(binary, ["work-item-get", id, "--as-user", smoke_user], work_dir, env)["workItem"]

    assert!(legacy["body"] == nil, "a new item must begin with an absent body")
    assert!(legacy["bodyUpdatedByUser"] == nil, "absent body user attribution")
    assert!(legacy["bodyUpdatedBySession"] == nil, "absent body session attribution")
    assert!(legacy["bodyUpdatedAt"] == nil, "absent body timestamp")

    updated =
      run_json!(
        binary,
        ["work-item-update", id, "--body", @body, "--as-user", smoke_user],
        work_dir,
        env
      )

    item = updated["workItem"] || raise("R41 body update missing workItem")
    assert!(not Map.has_key?(item, "body"), "body update response must be body-free")
    assert!(updated["bodyUpdate"]["state"] == "present", "body update descriptor state")

    detail =
      run_json!(binary, ["work-item-get", id, "--as-user", smoke_user], work_dir, env)["workItem"]

    IO.puts(
      "R41 input specRef=#{@spec_ref} specSha256=#{@spec_sha} body=#{inspect(@body)} bytes=#{byte_size(@body)}"
    )

    assert_detail!(detail, @body, smoke_user, id)
    IO.puts("R41 assertions=7 item=#{id}")
    {id, smoke_user}
  end

  defp run_restart_readback!(gateway, binary, item_id, smoke_user) do
    env = cli_env(gateway)
    work_dir = Path.join(gateway.base_dir, "work")
    IO.puts("R41 phase=restart-readback")
    run!(binary, ["version"], work_dir, env)

    detail =
      run_json!(binary, ["work-item-get", item_id, "--as-user", smoke_user], work_dir, env)["workItem"]

    assert_detail!(detail, @body, smoke_user, item_id)

    empty =
      run_json!(
        binary,
        ["work-item-update", item_id, "--body", "", "--as-user", smoke_user],
        work_dir,
        env
      )

    assert!(empty["bodyUpdate"]["state"] == "present", "empty body must remain present")
    empty_detail =
      run_json!(binary, ["work-item-get", item_id, "--as-user", smoke_user], work_dir, env)["workItem"]

    assert_detail!(empty_detail, "", smoke_user, item_id)

    cleared =
      run_json!(
        binary,
        ["work-item-update", item_id, "--clear-body", "--as-user", smoke_user],
        work_dir,
        env
      )

    assert!(cleared["bodyUpdate"]["state"] == "absent", "clear body descriptor")
    final =
      run_json!(binary, ["work-item-get", item_id, "--as-user", smoke_user], work_dir, env)["workItem"]

    assert!(final["body"] == nil, "clear body did not remove body")
    assert!(final["bodyUpdatedByUser"] == smoke_user, "clear attribution missing")
    assert!(is_integer(final["bodyUpdatedAt"]), "clear timestamp missing")
    assert_spec_ref!(final)
    IO.puts("R41 assertions=13 item=#{item_id}")
  end

  defp assert_detail!(detail, body, smoke_user, item_id) do
    assert!(detail["id"] == item_id, "readback item id mismatch")
    assert!(detail["body"] == body, "body bytes did not round-trip")
    assert!(detail["bodyUpdatedByUser"] == smoke_user, "body attribution missing")
    assert!(detail["bodyUpdatedBySession"] == nil, "unexpected session attribution")
    assert!(is_integer(detail["bodyUpdatedAt"]), "body timestamp missing")
    assert_spec_ref!(detail)
  end

  defp assert_spec_ref!(detail) do
    assert!(detail["specRefName"] == @spec_ref, "spec reference name changed")
    assert!(detail["specRefSha256"] == @spec_sha, "spec reference digest changed")
  end

  defp cli_env(gateway) do
    cleared =
      System.get_env()
      |> Map.keys()
      |> Enum.filter(fn key ->
        String.starts_with?(key, "TIGHTBEAM_") or String.starts_with?(key, "RELEASE_")
      end)
      |> Enum.map(&{&1, nil})

    cleared ++ [
      {"TIGHTBEAM_BASE_DIR", gateway.base_dir},
      {"TIGHTBEAM_PORT", Integer.to_string(gateway.port)}
    ]
  end

  defp run!(binary, args, work_dir, env) do
    case System.cmd(binary, args, cd: work_dir, env: env, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise("R41 CLI failed status=#{status}: #{output}")
    end
  end

  defp run_json!(binary, args, work_dir, env) do
    case System.cmd(binary, args, cd: work_dir, env: env, stderr_to_stdout: true) do
      {output, 0} -> JSON.decode!(output)
      {output, status} -> raise("R41 CLI failed status=#{status}: #{output}")
    end
  end

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise("R41 assertion failed: #{message}")

  defp teardown! do
    result =
      case {Process.get(:body_smoke_gateway), Process.get(:body_smoke_base)} do
        {%LegGateway{} = gateway, _base} -> LegGateway.teardown(gateway)
        {nil, base} ->
          if File.exists?(base) do
            case File.rm_rf(base) do
              {:ok, _removed} -> :ok
              {:error, reason, path} -> {:error, :not_removed, path, reason}
            end
          else
            :ok
          end
      end

    IO.puts("R41 teardown=#{inspect(result)}")
    if result != :ok, do: raise("R41 teardown failed: #{inspect(result)}")
  end

  defp seed_disposable_state!(base) do
    manifest_path = Path.join(Application.app_dir(:tightbeam), "build-manifest.json")
    manifest = manifest_path |> File.read!() |> JSON.decode!()

    File.write!(
      Path.join(base, "build-owner.json"),
      JSON.encode!(%{"format" => "tightbeam-build-owner/v1", "buildIdentity" => manifest["buildIdentity"]})
    )

    db_name = String.to_atom("body_smoke_seed_#{System.unique_integer([:positive])}")
    {:ok, db} = DB.start_link(path: ":memory:", name: db_name)

    try do
      :ok = Schema.ensure_all(db)
      state_path = Path.join(base, "state.db")
      escaped = String.replace(state_path, "'", "''")
      {:ok, _} = DB.query(db, "VACUUM INTO '#{escaped}'")
    after
      :ok = GenServer.stop(db)
    end
  end

  defp required_env!(name), do: System.get_env(name) || raise("R41 missing #{name}")

  defp require_dir!(path, label) do
    unless File.dir?(path), do: raise("R41 missing #{label}: #{path}")
  end

  defp require_file!(path, label) do
    unless File.regular?(path), do: raise("R41 missing #{label}: #{path}")
  end

  defp port!(value) do
    port = String.to_integer(value)
    if port < @min_port, do: raise("R41 port must be >= #{@min_port}"), else: port
  rescue
    ArgumentError -> raise("R41 invalid port: #{value}")
  end
end

WorkItemBodySmoke.run()
