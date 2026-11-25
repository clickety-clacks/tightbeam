defmodule Tightbeam.Harness.ClaudeCli do
  @moduledoc false

  alias Tightbeam.Harness.{Claude, Support}

  # The pinned ACP's bundled CLI meets Anthropic's minimum for Opus 5.5.
  @floor "2.1.280"
  @timeout_ms 10_000

  @probe ~S"""
  const fs = require('node:fs');
  const path = require('node:path');
  const { spawnSync } = require('node:child_process');
  const { pathToFileURL } = require('node:url');
  const [adapter, cwd] = process.argv.slice(1);

  function lookup(name) {
    for (const directory of (process.env.PATH || '').split(path.delimiter)) {
      const candidate = path.resolve(directory, name);
      try {
        fs.accessSync(candidate, fs.constants.X_OK);
        if (fs.statSync(candidate).isFile()) return candidate;
      } catch {}
    }
  }

  function checkCli(file, source) {
    if (!file) return { problem: source };
    // The SDK invokes script overrides through Node and native CLIs directly.
    const script = /\.(?:js|mjs|tsx|ts|jsx)$/.test(file);
    const executable = script || file.includes(path.sep) ? path.resolve(file) : lookup(file);
    if (!executable) return { problem: source };

    const command = script ? [process.execPath, executable] : [executable];
    const result = spawnSync(command[0], [...command.slice(1), '--version'],
      { encoding: 'utf8', timeout: 3000 });
    const version = /^((\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)(?:\s|$)/
      .exec((result.stdout || '').trim());
    if (result.status !== 0 || !version) return { problem: source };

    const [major, minor, patch] = floor.split('.').map(Number);
    const order = Number(version[2]) - major || Number(version[3]) - minor || Number(version[4]) - patch;
    return { source, version: version[1], executable, command,
      supported: order > 0 || (order === 0 && !version[5]) };
  }

  async function inspectLaunch() {
    if (cwd) process.chdir(cwd);
    const entry = fs.realpathSync(adapter);
    fs.accessSync(entry, fs.constants.X_OK);
    let dir = path.dirname(entry);
    while (!fs.existsSync(path.join(dir, 'package.json'))) {
      const parent = path.dirname(dir);
      if (parent === dir) return { problem: 'package' };
      dir = parent;
    }
    const pkg = JSON.parse(fs.readFileSync(path.join(dir, 'package.json'), 'utf8'));
    if (pkg.name !== '@agentclientprotocol/claude-agent-acp' ||
        ![expected, '0.59.0'].includes(pkg.version)) {
      return { problem: 'package' };
    }

    const override = process.env.CLAUDE_CODE_EXECUTABLE;
    const pinned = pkg.version === expected;
    if (override !== undefined) return { ...checkCli(override, 'override'), pinned };

    const cliOnPath = checkCli(lookup('claude'), 'path');
    if (cliOnPath.supported) return { ...cliOnPath, pinned };

    // Both the pinned and the known stale ACP package export the resolver
    // used by their sessions. Import it without starting ACP.
    try {
      const agent = pathToFileURL(path.join(dir, 'dist/acp-agent.js'));
      const bundle = await (await import(agent.href)).claudeCliPath();
      return { ...checkCli(bundle, 'bundle'), pinned };
    } catch {
      return { problem: 'bundle' };
    }
  }

  inspectLaunch()
    .catch(() => ({ problem: 'probe' }))
    .then(result => process.stdout.write(JSON.stringify(result)));
  """

  @doc "Check and pin the executable on the launch host before the adapter is started."
  def prepare_launch(opts, host, run) do
    case Support.bounded_run(run, command(opts), @timeout_ms) do
      {:ok, {output, 0}} when is_binary(output) ->
        with {:ok, selection} <- selection_result(output, host) do
          {:ok, put_executable(opts, selection["executable"])}
        end

      _ ->
        refusal(host, "could not check the Claude Code executable on the launch host")
    end
  end

  @doc false
  def selection_args(adapter, cwd),
    do: ["node", "-e", selection_program(), adapter, cwd]

  @doc false
  def selection_program do
    "const expected = #{JSON.encode!(Claude.adapter_version())};\n" <>
      "const floor = #{JSON.encode!(@floor)};\n" <> @probe
  end

  @doc false
  def selection_result(output, host), do: check_result(JSON.decode(String.trim(output)), host)

  defp put_executable(opts, executable) do
    if Keyword.get(opts, :process_ssh) do
      {adapter, command} = List.pop_at(Keyword.fetch!(opts, :cmd), -1)
      pin = "CLAUDE_CODE_EXECUTABLE=" <> Support.shell_quote(executable)
      Keyword.put(opts, :cmd, command ++ [pin, adapter])
    else
      env =
        Enum.reject(Keyword.get(opts, :env, []), fn {name, _} ->
          name == "CLAUDE_CODE_EXECUTABLE"
        end)

      Keyword.put(opts, :env, env ++ [{"CLAUDE_CODE_EXECUTABLE", executable}])
    end
  end

  defp command(opts) do
    cmd = Keyword.fetch!(opts, :cmd)
    adapter = List.last(cmd)

    if Keyword.get(opts, :process_ssh) do
      # Keep only the executable selection environment from the launch command.
      # Other assignments can contain credentials or command substitutions.
      {ssh, ["exec", "env" | env_and_adapter]} = Enum.split_while(cmd, &(&1 != "exec"))

      env =
        env_and_adapter
        |> Enum.drop(-1)
        |> Enum.filter(&String.starts_with?(&1, ["PATH=", "CLAUDE_CODE_EXECUTABLE="]))

      probe = Enum.map(selection_args(adapter, ""), &Support.shell_quote/1)
      ssh ++ ["exec", "env" | env ++ probe]
    else
      env =
        opts
        |> Keyword.get(:env, [])
        |> Enum.filter(fn {name, _} -> name in ["PATH", "CLAUDE_CODE_EXECUTABLE"] end)
        |> Enum.map(fn {name, value} -> name <> "=" <> value end)

      ["/usr/bin/env" | env ++ selection_args(adapter, Keyword.fetch!(opts, :cwd))]
    end
  end

  defp check_result(
         {:ok, %{"source" => source, "version" => version, "supported" => false} = result},
         host
       )
       when source in ["override", "bundle"] do
    reason = "#{label(source)} reports #{version}. Claude Code #{@floor} or newer is required"
    refusal(host, if(result["pinned"], do: reason, else: reason <> ". " <> package_remedy()))
  end

  defp check_result({:ok, %{"supported" => true, "pinned" => true} = selection}, _host),
    do: {:ok, selection}

  defp check_result({:ok, %{"pinned" => false}}, host), do: refusal(host, package_remedy())
  defp check_result({:ok, %{"problem" => "package"}}, host), do: refusal(host, package_remedy())

  defp check_result({:ok, %{"problem" => source}}, host) when source in ["override", "bundle"],
    do: refusal(host, "could not run #{label(source)} with --version")

  defp check_result(_, host),
    do: refusal(host, "could not resolve the Claude ACP executable or its SDK on the launch host")

  defp label("override"), do: "the CLAUDE_CODE_EXECUTABLE override"
  defp label("bundle"), do: "the bundled Claude Code executable"

  defp package_remedy,
    do: "the Claude ACP package must be reconciled to #{Claude.adapter_version()}"

  defp refusal(host, reason),
    do:
      {:error,
       %{code: "claude_cli_unready", message: "Claude is not ready on #{host}: #{reason}."}}
end
