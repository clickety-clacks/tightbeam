defmodule Tightbeam.HarnessProcessCensus do
  @moduledoc false

  # Identity files find fixture groups even after exec has replaced every trace of
  # the fixture path. The command match catches the timed-out helper that exposed
  # this defect even when its test root has already been removed. `ps` is used
  # directly because macOS pgrep -f did not match that real command line.
  @fixture_command ~r{(?:^|\s)\S*/harness-process-\d+-\d+/\S+}

  def capture do
    capture(fixture_identity_paths(), @fixture_command)
  end

  def capture_for_root(root) do
    capture(
      Path.wildcard(Path.join(root, "**/harness-processes/*.identity")),
      ~r{(?:^|\s)#{Regex.escape(root)}/\S+}
    )
  end

  defp capture(identity_paths, fixture_command) do
    output =
      case System.cmd("ps", ["-axo", "pid=,pgid=,command="], stderr_to_stdout: true) do
        {output, 0} ->
          output

        {output, status} ->
          raise "process census ps failed (status #{status}): #{String.trim(output)}"
      end

    processes = parse_ps(output)
    fixture_groups = fixture_process_groups(identity_paths)

    processes =
      Enum.filter(processes, fn process ->
        MapSet.member?(fixture_groups, process.pgid) or
          Regex.match?(fixture_command, process.command)
      end)

    %{count: length(processes), processes: processes}
  end

  def format(%{count: count, processes: processes}) do
    rows =
      Enum.map_join(processes, "\n", fn process ->
        "pid=#{process.pid} pgid=#{process.pgid} command=#{process.command}"
      end)

    if rows == "" do
      "harness fixture processes: #{count}"
    else
      "harness fixture processes: #{count}\n#{rows}"
    end
  end

  def parse_ps(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*(\d+)\s+(\d+)\s+(.*)$/, line, capture: :all_but_first) do
        [pid, pgid, command] ->
          [%{pid: String.to_integer(pid), pgid: String.to_integer(pgid), command: command}]

        nil ->
          []
      end
    end)
  end

  defp fixture_process_groups(identity_paths) do
    identity_paths
    |> Enum.flat_map(fn identity_path ->
      with {:ok, identity} <- File.read(identity_path),
           [_, process_group_id | _] <- identity |> String.trim() |> String.split("\t"),
           {process_group_id, ""} <- Integer.parse(process_group_id) do
        [process_group_id]
      else
        _ -> []
      end
    end)
    |> MapSet.new()
  end

  defp fixture_identity_paths do
    suite_tmp = Application.get_env(:tightbeam, :test_suite_tmp)

    roots =
      if is_binary(suite_tmp) do
        Path.wildcard(Path.join(Path.dirname(suite_tmp), "tightbeam-test-*"))
      else
        Path.wildcard(Path.join(System.tmp_dir!(), "tightbeam-test-*"))
      end

    Enum.flat_map(roots, &Path.wildcard(Path.join(&1, "**/harness-processes/*.identity")))
  end
end
