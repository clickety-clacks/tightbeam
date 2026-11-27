import ExUnit.Assertions
alias Tightbeam.{AdapterCoordinator, Gateway, Placement}
alias Tightbeam.Harness.{Claude, Support}

write_executable = fn path, body ->
  File.write!(path, "#!/bin/sh\n#{body}\n")
  File.chmod!(path, 0o755)
end

Tightbeam.GuardGatewayFixture.run!(fn %{base: base, config: config, db: db} ->
  System.delete_env("CLAUDE_CODE_EXECUTABLE")
  {node, 0} = System.cmd("node", ["-p", "process.execPath"])
  node = node |> String.trim() |> Support.shell_quote()
  bin = Path.join(base, "toolchain")
  File.mkdir_p!(bin)

  write_executable.(Path.join(bin, "node"), """
  echo 'fixture version probe warning' >&2
  exec #{node} "$@"
  """)

  path_cli = Path.join(bin, "claude")
  write_executable.(path_cli, "echo '2.1.207 (Claude Code)'")

  root = Path.join(base, "adapters")
  installed = Claude.installed_adapter(root)
  package = Path.join(root, "node_modules/@agentclientprotocol/claude-agent-acp")
  dist = Path.join(package, "dist")
  File.mkdir_p!(dist)
  File.mkdir_p!(Path.dirname(installed))

  File.write!(
    Path.join(package, "package.json"),
    JSON.encode!(%{
      name: Claude.install_package(),
      version: Claude.adapter_version(),
      type: "module"
    })
  )

  bundled_cli = Path.join(package, "claude")
  write_executable.(bundled_cli, "echo '2.1.207 (Claude Code)'")

  File.write!(Path.join(dist, "acp-agent.js"), """
  export function claudeCliPath() {
    return #{JSON.encode!(bundled_cli)};
  }
  """)

  observed_cli = Path.join(base, "launched-claude")
  protocol = Path.join(dist, "fixture.cjs")

  File.write!(protocol, """
  const fs = require('node:fs');
  const input = require('node:readline').createInterface({input: process.stdin});
  input.on('line', line => {
    const request = JSON.parse(line);
    if (request.method === 'initialize') {
      fs.writeFileSync(#{JSON.encode!(observed_cli)}, process.env.CLAUDE_CODE_EXECUTABLE || '');
      process.stdout.write(JSON.stringify({
        jsonrpc: '2.0', id: request.id, result: {protocolVersion: 1}
      }) + '\\n');
    }
  });
  """)

  entry = Path.join(dist, "index.js")
  write_executable.(entry, "exec #{node} #{Support.shell_quote(protocol)}")
  File.ln_s!(entry, installed)

  assert {:ok, _} = Placement.set_toolchain_dirs(db, "testhost", [bin], "test")

  children = Gateway.children(%{config | port: 0})
  {AdapterCoordinator, opts} = Enum.find(children, &match?({AdapterCoordinator, _}, &1))

  {:ok, supervisor} =
    DynamicSupervisor.start_link(strategy: :one_for_one, name: Tightbeam.AdapterSupervisor)

  {:ok, coordinator} = AdapterCoordinator.start_link(opts)
  key = {:claude, "shared", "testhost"}

  try do
    assert {:error, {:launch_refused, %{code: "claude_cli_unready", message: message}}} =
             AdapterCoordinator.adapter_for(coordinator, key)

    assert message =~ "bundled Claude Code executable reports 2.1.207"
    assert AdapterCoordinator.harness_processes(coordinator) == []
    refute File.exists?(observed_cli)

    write_executable.(path_cli, "echo '2.1.322 (Claude Code)'")
    assert {:ok, adapter, _generation} = AdapterCoordinator.adapter_for(coordinator, key)
    assert is_pid(Tightbeam.Acp.Adapter.conn(adapter))
    assert File.read!(observed_cli) == path_cli
  after
    GenServer.stop(coordinator)
    Supervisor.stop(supervisor)
  end
end)

IO.puts("guarded-gateway-claude-cli: ok")
