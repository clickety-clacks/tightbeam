alias Tightbeam.ClientE2E.{LegGateway, SimClient, WS}

defmodule Tightbeam.FirehoseRestartSmoke do
  @moduledoc false

  def run do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        # LegGateway recognizes this marker as a run-local tree it may remove after a clean stop.
        "tightbeam-client-e2e-firehose-restart-#{System.unique_integer([:positive])}"
      )

    port = 12_800 + rem(System.unique_integer([:positive]), 500)
    File.mkdir_p!(base_dir)
    gateway = LegGateway.boot!(base_dir, port, repo_root: File.cwd!())

    try do
      {:ok, device} =
        SimClient.pair("127.0.0.1", port,
          device_id: "firehose-restart-smoke",
          claimed_name: "Firehose restart smoke"
        )

      cli_token = gateway_token(base_dir)
      ws = connect(port, device.token)

      {:ok, pre_auth_ws} =
        WS.connect("127.0.0.1", port, "/ws/changes?protocolVersion=1")

      first = create_item(port, cli_token, device.user_id, "Before gateway restart")
      {first_notice, ws} = recv_change(ws)
      first_model = %{first_notice["refs"]["workItemId"] => first_notice["payload"]}
      true = Map.has_key?(first_model, first)

      restart = Task.async(fn -> LegGateway.restart(gateway, repo_root: File.cwd!()) end)
      {:ok, {:closed, 1012}, _ws} = recv_close(ws, 30_000)
      {:ok, {:closed, 1012}, _pre_auth_ws} = recv_close(pre_auth_ws, 30_000)
      {:ok, restarted} = Task.await(restart, 120_000)
      Process.put(:firehose_restart_gateway, restarted)

      ws = connect(port, device.token)
      rebuilt = snapshot(port, cli_token, device.user_id)
      true = Map.has_key?(rebuilt, first)

      second = create_item(port, cli_token, device.user_id, "After gateway restart")
      {second_notice, ws} = recv_change(ws)
      rebuilt = Map.put(rebuilt, second_notice["refs"]["workItemId"], second_notice["payload"])
      true = Map.has_key?(rebuilt, second)
      true = rebuilt == snapshot(port, cli_token, device.user_id)
      :ok = WS.close(ws)

      IO.puts(
        "PASS gateway_pid=#{gateway.os_pid} restarted_pid=#{restarted.os_pid} " <>
          "close_code=1012 pre_auth_close_code=1012 rebuilt=#{map_size(rebuilt)}"
      )
    after
      active = Process.get(:firehose_restart_gateway, gateway)
      result = LegGateway.teardown(active)
      Process.delete(:firehose_restart_gateway)

      unless result == :ok do
        IO.puts(:stderr, "firehose restart smoke teardown failed: #{inspect(result)}")
      end
    end
  end

  defp connect(port, token) do
    {:ok, ws} = WS.connect("127.0.0.1", port, "/ws/changes?protocolVersion=1")
    :ok = WS.send_text(ws, JSON.encode!(%{"type" => "auth", "token" => token}))
    {:ok, {:text, auth}, ws} = WS.recv(ws, 5_000)
    %{"type" => "auth_result", "success" => true} = JSON.decode!(auth)

    :ok =
      WS.send_text(
        ws,
        JSON.encode!(%{
          "type" => "subscribe",
          "protocolVersion" => 1,
          "subscriptionId" => "work-items",
          "filters" => %{"classes" => ["work_item."]}
        })
      )

    {:ok, {:text, ready}, ws} = WS.recv(ws, 5_000)
    %{"type" => "subscription_ready"} = JSON.decode!(ready)
    ws
  end

  defp recv_change(ws) do
    case WS.recv(ws, 5_000) do
      {:ok, {:text, bytes}, ws} ->
        case JSON.decode!(bytes) do
          %{"type" => "change"} = notice -> {notice, ws}
          _other -> recv_change(ws)
        end

      other ->
        raise "change socket closed before notice: #{inspect(other)}"
    end
  end

  defp recv_close(ws, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    recv_close_until(ws, deadline)
  end

  defp recv_close_until(ws, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case WS.recv_event(ws, remaining) do
      {:ok, {:closed, _code}, _ws} = closed -> closed
      {:ok, {:text, _bytes}, ws} -> recv_close_until(ws, deadline)
      other -> other
    end
  end

  defp create_item(port, token, user_id, title) do
    %{"result" => %{"id" => id}} =
      dispatch(port, token, user_id, "work-item-create", %{"title" => title})

    id
  end

  defp snapshot(port, token, user_id) do
    %{"result" => %{"workItems" => items}} =
      dispatch(port, token, user_id, "work-item-list", %{})

    Map.new(items, &{&1["id"], Tightbeam.StateResources.work_item(&1)})
  end

  defp dispatch(port, token, user_id, verb, params) do
    body = JSON.encode!(%{"verb" => verb, "asUser" => user_id, "params" => params})
    url = ~c"http://127.0.0.1:#{port}/agent/dispatch"

    {:ok, {{_version, 200, _reason}, _headers, response}} =
      :httpc.request(
        :post,
        {url,
         [
           {~c"authorization", ~c"Bearer #{token}"},
           {~c"x-tightbeam-cli-version",
            String.to_charlist(Tightbeam.CliCompatibility.required_version())},
           {~c"content-type", ~c"application/json"}
         ], ~c"application/json", body},
        [{:timeout, 5_000}],
        body_format: :binary
      )

    JSON.decode!(response)
  end

  defp gateway_token(base_dir) do
    %{"cliToken" => token} =
      base_dir |> Path.join("gateway.json") |> File.read!() |> JSON.decode!()

    token
  end
end

Tightbeam.FirehoseRestartSmoke.run()
