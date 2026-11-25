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
  const [adapter, cwd, expected] = process.argv.slice(1);

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
    const source = override === undefined ? 'bundle' : 'override';
    let cli = override;
    if (source === 'bundle') {
      // Both the pinned and the known stale ACP package export the very
      // resolver used by their sessions. Import it without starting ACP.
      try {
        const agent = pathToFileURL(path.join(dir, 'dist/acp-agent.js'));
        cli = await (await import(agent.href)).claudeCliPath();
      } catch {
        return { problem: source };
      }
    }

    if (!cli) return { problem: source };
    // The SDK invokes script overrides through Node and native CLIs directly.
    const script = /\.(?:js|mjs|tsx|ts|jsx)$/.test(cli);
    const command = script ? process.execPath : cli;
    const args = script ? [cli, '--version'] : ['--version'];
    const result = spawnSync(command, args, { encoding: 'utf8', timeout: 3000 });
    const match = /^([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)(?:\s|$)/
      .exec((result.stdout || '').trim());
    return result.status === 0 && match
      ? { source, version: match[1], pinned: pkg.version === expected }
      : { problem: source };
  }

  inspectLaunch()
    .catch(() => ({ problem: 'probe' }))
    .then(result => process.stdout.write(JSON.stringify(result)));
  """

  @doc "Check the Claude executable on the launch host before the adapter is started."
  def check_launch(opts, host, run) do
    case Support.bounded_run(run, command(opts), @timeout_ms) do
      {:ok, {output, 0}} when is_binary(output) ->
        check_result(JSON.decode(String.trim(output)), host)

      _ ->
        refusal(host, "could not check the Claude Code executable on the launch host")
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

      probe = Enum.map(probe_args(adapter, ""), &Support.shell_quote/1)
      ssh ++ ["exec", "env" | env ++ probe]
    else
      env =
        opts
        |> Keyword.get(:env, [])
        |> Enum.filter(fn {name, _} -> name in ["PATH", "CLAUDE_CODE_EXECUTABLE"] end)
        |> Enum.map(fn {name, value} -> name <> "=" <> value end)

      ["/usr/bin/env" | env ++ probe_args(adapter, Keyword.fetch!(opts, :cwd))]
    end
  end

  defp probe_args(adapter, cwd),
    do: ["node", "-e", @probe, adapter, cwd, Claude.adapter_version()]

  defp check_result({:ok, %{"source" => source, "version" => version, "pinned" => pinned}}, host)
       when source in ["override", "bundle"] and is_binary(version) do
    case Version.parse(version) do
      {:ok, parsed} ->
        cond do
          Version.compare(parsed, @floor) == :lt ->
            reason =
              "#{label(source)} reports #{version}. Claude Code #{@floor} or newer is required"

            refusal(host, if(pinned, do: reason, else: reason <> ". " <> package_remedy()))

          pinned == true ->
            :ok

          true ->
            refusal(host, package_remedy())
        end

      :error ->
        refusal(host, "could not read the version of #{label(source)}")
    end
  end

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
