alias Tightbeam.ClientE2E.LegGateway

defmodule Tightbeam.WorkItemBodySmoke do
  @moduledoc false

  @spec run() :: :ok
  def run do
    repo_root = File.cwd!()
    template = env!("TIGHTBEAM_WORK_ITEM_BODY_SMOKE_TEMPLATE") |> Path.expand()
    port = smoke_port!()
    binary = Path.join(repo_root, "cli/target/release/tightbeam")
    assert_binary!(binary)
    assert_port_free!(port)

    run_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-work-item-body-client-e2e-#{System.unique_integer([:positive])}"
      )

    work_dir = Path.join(run_dir, "work")
    IO.puts("work-item body smoke provision run_dir=#{run_dir} template=#{template} port=#{port}")
    LegGateway.provision!(template, run_dir)
    assert_state_free!(run_dir)
    File.mkdir_p!(work_dir)

    Process.put(:work_item_body_smoke_gateway, nil)
    Process.put(:work_item_body_smoke_teardown, nil)

    evidence =
      try do
        gateway = boot!(run_dir, port, repo_root)
        Process.put(:work_item_body_smoke_gateway, gateway)

        run_cli!(binary, work_dir, run_dir, "add-user", ["add-user", "smoke-admin", "--admin"])

        spec_name = "specs/smoke/work-item-body.md"
        spec_sha = String.duplicate("a", 64)

        created =
          run_cli!(binary, work_dir, run_dir, "create", [
            "work-item-create",
            "--title",
            "Work-item body restart smoke",
            "--spec-ref",
            spec_name,
            "--spec-sha256",
            spec_sha,
            "--as-user",
            "smoke-admin"
          ])

        work_item_id = required_string!(created, "id", "create")
        body = "  Smoke ✓ \"quoted\"\nline two #{System.unique_integer([:positive])}\n"

        updated =
          run_cli!(binary, work_dir, run_dir, "replace-body", [
            "work-item-update",
            work_item_id,
            "--body",
            body,
            "--as-user",
            "smoke-admin"
          ])

        assert_update!(updated, work_item_id, spec_name, spec_sha, "present", byte_size(body))

        before_restart = get!(binary, work_dir, run_dir, work_item_id)
        assert_detail!(before_restart, work_item_id, body, "smoke-admin", spec_name, spec_sha)

        restarted = restart!(gateway, repo_root)
        Process.put(:work_item_body_smoke_gateway, restarted)

        after_restart = get!(binary, work_dir, run_dir, work_item_id)
        assert_detail!(after_restart, work_item_id, body, "smoke-admin", spec_name, spec_sha)

        emptied =
          run_cli!(binary, work_dir, run_dir, "empty-body", [
            "work-item-update",
            work_item_id,
            "--body=",
            "--as-user",
            "smoke-admin"
          ])

        assert_update!(emptied, work_item_id, spec_name, spec_sha, "present", 0)
        empty_detail = get!(binary, work_dir, run_dir, work_item_id)
        assert_detail!(empty_detail, work_item_id, "", "smoke-admin", spec_name, spec_sha)

        cleared =
          run_cli!(binary, work_dir, run_dir, "clear-body", [
            "work-item-update",
            work_item_id,
            "--clear-body",
            "--as-user",
            "smoke-admin"
          ])

        assert_update!(cleared, work_item_id, spec_name, spec_sha, "absent", 0)
        clear_detail = get!(binary, work_dir, run_dir, work_item_id)
        assert_detail!(clear_detail, work_item_id, nil, "smoke-admin", spec_name, spec_sha)

        %{
          run_dir: run_dir,
          binary: binary,
          work_item_id: work_item_id,
          first_pid: gateway.os_pid,
          restarted_pid: restarted.os_pid,
          body_bytes: byte_size(body)
        }
      after
        teardown!(Process.get(:work_item_body_smoke_gateway), run_dir)
        Process.delete(:work_item_body_smoke_gateway)
      end

    IO.puts(
      "PASS work_item_id=#{evidence.work_item_id} body_bytes=#{evidence.body_bytes} " <>
        "first_pid=#{evidence.first_pid} restarted_pid=#{evidence.restarted_pid} " <>
        "binary=#{evidence.binary} run_dir=#{evidence.run_dir} teardown=ok"
    )

    :ok
  end

  defp boot!(run_dir, port, repo_root) do
    case LegGateway.boot(run_dir, port, repo_root: repo_root) do
      {:ok, gateway} ->
        gateway

      {:error, reason, gateway} ->
        Process.put(:work_item_body_smoke_gateway, gateway)
        raise "work-item body smoke boot failed: #{inspect(reason)}; log=#{gateway.log_path}"
    end
  end

  defp restart!(gateway, repo_root) do
    case LegGateway.restart(gateway, repo_root: repo_root) do
      {:ok, restarted} ->
        restarted

      {:error, reason, restarted} ->
        Process.put(:work_item_body_smoke_gateway, restarted)

        raise "work-item body smoke restart failed: #{inspect(reason)}; run_dir=#{restarted.base_dir}"

      {:error, reason} ->
        raise "work-item body smoke restart failed: #{inspect(reason)}; run_dir=#{gateway.base_dir}"
    end
  end

  defp teardown!(nil, run_dir) do
    case File.rm_rf(run_dir) do
      {:ok, _removed} ->
        :ok

      {:error, reason, path} ->
        raise "work-item body smoke cleanup failed at #{path}: #{inspect(reason)}"
    end
  end

  defp teardown!(gateway, run_dir) do
    result = LegGateway.teardown(gateway, [])
    Process.put(:work_item_body_smoke_teardown, result)

    unless result == :ok do
      raise "work-item body smoke teardown failed: #{inspect(result)}; run_dir kept at #{run_dir}"
    end
  end

  defp get!(binary, work_dir, run_dir, work_item_id) do
    run_cli!(binary, work_dir, run_dir, "get-body", [
      "work-item-get",
      work_item_id,
      "--as-user",
      "smoke-admin"
    ])
  end

  defp run_cli!(binary, work_dir, run_dir, phase, args) do
    {output, status} =
      System.cmd(binary, args,
        cd: work_dir,
        env: [
          {"TIGHTBEAM_BASE_DIR", run_dir},
          {"TIGHTBEAM_HOME", nil},
          {"TIGHTBEAM_URL", nil},
          {"TIGHTBEAM_TOKEN", nil}
        ],
        stderr_to_stdout: true
      )

    if status != 0 do
      raise "work-item body smoke #{phase} failed with exit #{status}: #{String.trim(output)}"
    end

    case JSON.decode(output) do
      {:ok, decoded} when is_map(decoded) ->
        decoded

      {:ok, decoded} ->
        raise "work-item body smoke #{phase} returned non-object JSON: #{inspect(decoded)}"

      {:error, reason} ->
        raise "work-item body smoke #{phase} returned invalid JSON: #{inspect(reason)}; output=#{inspect(output)}"
    end
  end

  defp assert_update!(result, work_item_id, spec_name, spec_sha, state, byte_length) do
    with %{"workItem" => item, "bodyUpdate" => descriptor} <- result,
         ^work_item_id <- item["id"],
         ^spec_name <- item["specRefName"],
         ^spec_sha <- item["specRefSha256"],
         ^state <- descriptor["state"],
         ^byte_length <- descriptor["byteLength"],
         true <- is_boolean(descriptor["changed"]),
         false <- Map.has_key?(item, "body") do
      :ok
    else
      mismatch ->
        raise "work-item body smoke update assertion failed: #{inspect(mismatch)}; result=#{inspect(result)}"
    end
  end

  defp assert_detail!(result, work_item_id, body, user, spec_name, spec_sha) do
    with %{"workItem" => item} <- result,
         ^work_item_id <- item["id"],
         ^body <- item["body"],
         ^user <- item["bodyUpdatedByUser"],
         nil <- item["bodyUpdatedBySession"],
         updated_at when is_integer(updated_at) <- item["bodyUpdatedAt"],
         ^spec_name <- item["specRefName"],
         ^spec_sha <- item["specRefSha256"] do
      :ok
    else
      mismatch ->
        raise "work-item body smoke get assertion failed: #{inspect(mismatch)}; result=#{inspect(result)}"
    end
  end

  defp required_string!(map, key, phase) do
    case map[key] do
      value when is_binary(value) and value != "" -> value
      value -> raise "work-item body smoke #{phase} missing #{key}: #{inspect(value)}"
    end
  end

  defp assert_state_free!(run_dir) do
    for relative <- ["state.db", "gateway.json", "logs", "work"],
        File.exists?(Path.join(run_dir, relative)) do
      raise "work-item body smoke provision copied forbidden state: #{relative}"
    end
  end

  defp assert_binary!(binary) do
    unless File.regular?(binary) do
      raise "work-item body smoke built CLI missing: #{binary}"
    end

    case System.cmd(binary, ["--version"], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        raise "work-item body smoke built CLI is not executable (#{status}): #{String.trim(output)}"
    end
  end

  defp assert_port_free!(port) do
    case :gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, reason} ->
        raise "work-item body smoke port #{port} is unavailable: #{inspect(reason)}"
    end
  end

  defp smoke_port! do
    raw = env!("TIGHTBEAM_WORK_ITEM_BODY_SMOKE_PORT")

    case Integer.parse(raw) do
      {port, ""} when port >= 12_000 and port <= 65_535 ->
        port

      _ ->
        raise "TIGHTBEAM_WORK_ITEM_BODY_SMOKE_PORT must be an integer from 12000 through 65535 (got #{inspect(raw)})"
    end
  end

  defp env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> raise "missing #{name}"
    end
  end
end

Tightbeam.WorkItemBodySmoke.run()
