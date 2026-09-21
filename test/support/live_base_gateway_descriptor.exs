import ExUnit.Assertions
alias Tightbeam.Gateway

Tightbeam.GuardGatewayFixture.run!(fn %{config: config, base: base} ->
  original = System.get_env("RELEASE_NODE")
  shim = Path.join(base, "release/bin/tightbeam-gateway")
  rel_bin = Path.join(base, "release/release/bin")
  File.mkdir_p!(Path.dirname(shim))
  File.mkdir_p!(rel_bin)
  File.cp!(Path.expand("../../packaging/tightbeam-gateway", __DIR__), shim)
  File.chmod!(shim, 0o755)

  fake = Path.join(rel_bin, "tightbeam_gateway")

  File.write!(
    fake,
    "#!/bin/sh\n" <>
      "printf 'REL_NODE=%s\\n' \"$RELEASE_NODE\"\n" <>
      "printf 'REL_COOKIE=%s\\n' \"${RELEASE_COOKIE-<unset>}\"\n" <>
      "for a in \"$@\"; do printf 'ARG=%s\\n' \"$a\"; done\n"
  )

  File.chmod!(fake, 0o755)

  try do
    # R5: the descriptor records the node the instance actually booted under;
    # the pid, command, and start time form the stop identity.
    System.put_env("RELEASE_NODE", "tightbeam_gateway_4321")
    Gateway.children(config)
    first = base |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()

    assert first["node"] == "tightbeam_gateway_4321"
    assert first["ownedPid"] == System.pid()
    assert is_binary(first["ownedCommand"]) and first["ownedCommand"] != ""
    assert is_binary(first["ownedStart"]) and first["ownedStart"] != ""

    System.put_env("RELEASE_NODE", "custom_operator_node")
    Gateway.children(config)
    second = base |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()

    assert second["node"] == "custom_operator_node"
    assert second["cliToken"] == first["cliToken"]

    # The committed shim must resolve the node persisted by the real writer,
    # never the ambient node or cookie supplied by the caller.
    System.put_env("RELEASE_NODE", "seam_custom_node")
    Gateway.children(config)

    {out, status} =
      System.cmd(shim, ["rpc", "Foo.bar()"],
        env: [
          {"TIGHTBEAM_BASE_DIR", base},
          {"RELEASE_NODE", "tightbeam_gateway_11373"},
          {"RELEASE_COOKIE", "prod-shared-cookie"}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ ~r/^REL_NODE=seam_custom_node$/m
    refute out =~ ~r/^REL_NODE=tightbeam_gateway_11373$/m
    assert out =~ ~r/^REL_COOKIE=<unset>$/m
    refute out =~ ~r/prod-shared-cookie/
  after
    if original,
      do: System.put_env("RELEASE_NODE", original),
      else: System.delete_env("RELEASE_NODE")
  end
end)

IO.puts("guarded-gateway-descriptor: ok")
