defmodule Tightbeam.ListenerLifecycleTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.{DB, Diagnostics, ListenerLifecycle, RequestContext, Schema, Wakes}
  alias Tightbeam.Wire.Router

  defmodule BoundPlug do
    def init(opts), do: opts
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 200, "ok")
  end

  # A gate at the child start seam makes the restart gap deterministic, without
  # adding delay controls to the production listener or depending on sleeps.
  def start_gated_listener(opts, owner, parent, counter) do
    if :atomics.add_get(counter, 1, 1) > 1 do
      send(parent, {:listener_gap, self()})

      receive do
        :bind_again -> :ok
      end
    end

    ListenerLifecycle.start_listener(opts, owner)
  end

  test "real Wakes crash preserves owners and correlates both bound HTTP instances" do
    parent = self()
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    owner = __MODULE__.Owner
    wakes = __MODULE__.Wakes
    counter = :atomics.new(1, [])

    opts = [
      plug: {Router, [db: db, cli_token: "sentinel_token"]},
      port: 0,
      ip: {127, 0, 0, 1},
      startup_log: false
    ]

    listener = ListenerLifecycle.listener_spec(opts, owner)

    listener = %{
      listener
      | id: :listener,
        start: {__MODULE__, :start_gated_listener, [opts, owner, parent, counter]}
    }

    # These are the real children in the same relevant rest_for_one order as
    # Application + Gateway; unrelated runtime/adapter children are omitted.
    children = [
      {Diagnostics, notify: parent},
      {ListenerLifecycle, name: owner},
      {Wakes, db: db, deliver: fn _ -> :ok end, name: wakes, tick_ms: 60_000},
      listener
    ]

    supervisor =
      start_supervised!(%{
        id: :restart_fixture,
        start: {Supervisor, :start_link, [children, [strategy: :rest_for_one]]}
      })

    assert_receive {:diagnostic, %{event: "listener_started", listener_generation: first}}, 2_000
    assert first =~ ~r/\Algen_[A-Za-z0-9_-]{22}\z/
    owner_pid = Process.whereis(owner)
    sink_pid = Process.whereis(Diagnostics)
    bandit = child(supervisor, :listener)
    {:ok, {_, port}} = ThousandIsland.listener_info(bandit)
    request_id = RequestContext.id("req_")
    assert {404, headers} = request(port, request_id)
    assert {~c"x-tightbeam-listener-generation", String.to_charlist(first)} in headers

    assert_receive {:diagnostic,
                    %{
                      event: "http_response_terminal",
                      request_id: ^request_id,
                      listener_generation: ^first,
                      response_state: "complete"
                    }},
                   2_000

    Process.exit(Process.whereis(wakes), :kill)
    assert_receive {:listener_gap, root}, 2_000
    assert Process.whereis(owner) == owner_pid
    assert Process.whereis(Diagnostics) == sink_pid
    assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [], 1_000)
    # Wait for the actual monitor observation before the next bind, proving
    # that the stopped generation belongs to the first socket's instance.
    assert_receive {:diagnostic,
                    %{
                      event: "listener_stopped",
                      listener_generation: ^first,
                      cause: "listener_child_exit"
                    }},
                   2_000

    send(root, :bind_again)
    assert_receive {:diagnostic, %{event: "listener_started", listener_generation: second}}, 2_000
    refute second == first
    {:ok, {_, port2}} = ThousandIsland.listener_info(child(supervisor, :listener))
    id2 = RequestContext.id("req_")
    assert {404, headers2} = request(port2, id2)
    assert {~c"x-tightbeam-listener-generation", String.to_charlist(second)} in headers2

    assert_receive {:diagnostic,
                    %{
                      event: "http_response_terminal",
                      request_id: ^id2,
                      listener_generation: ^second
                    }},
                   2_000

    records = Diagnostics.records()
    refute Enum.any?(records, &(&1.event == "listener_predecessor_stop_unknown"))
    refute inspect(records) =~ "sentinel_token"
  end

  test "a rejected stop record produces unknown before the successor start" do
    parent = self()

    emit = fn record ->
      send(parent, {:record, record})
      if record.event == "listener_stopped", do: :dropped, else: :accepted
    end

    owner = start_supervised!({ListenerLifecycle, name: nil, emit: emit})

    first =
      start_supervised!(%{
        ListenerLifecycle.listener_spec(
          [plug: BoundPlug, port: 0, ip: {127, 0, 0, 1}, startup_log: false],
          owner
        )
        | id: :first
      })

    assert_receive {:record, %{event: "listener_started", listener_generation: gen1}}, 2_000
    stop_supervised!(:first)
    refute Process.alive?(first)
    assert_receive {:record, %{event: "listener_stopped", listener_generation: ^gen1}}, 2_000

    start_supervised!(%{
      ListenerLifecycle.listener_spec(
        [plug: BoundPlug, port: 0, ip: {127, 0, 0, 1}, startup_log: false],
        owner
      )
      | id: :second
    })

    assert_receive {:record,
                    %{
                      event: "listener_predecessor_stop_unknown",
                      listener_generation: gen2,
                      prior_listener_generation: ^gen1,
                      cause: "listener_stop_unobserved"
                    }},
                   2_000

    assert_receive {:record, %{event: "listener_started", listener_generation: ^gen2}}, 2_000
    refute gen1 == gen2
  end

  test "lost owner memory makes no predecessor claim" do
    start_supervised!({Diagnostics, notify: self()})

    owner =
      start_supervised!(%{id: :owner, start: {ListenerLifecycle, :start_link, [[name: nil]]}})

    start_supervised!(%{
      ListenerLifecycle.listener_spec(
        [plug: BoundPlug, port: 0, ip: {127, 0, 0, 1}, startup_log: false],
        owner
      )
      | id: :first
    })

    assert_receive {:diagnostic, %{event: "listener_started", listener_generation: first}}, 2_000
    stop_supervised!(:first)
    stop_supervised!(:owner)

    owner2 =
      start_supervised!(%{id: :owner2, start: {ListenerLifecycle, :start_link, [[name: nil]]}})

    start_supervised!(%{
      ListenerLifecycle.listener_spec(
        [plug: BoundPlug, port: 0, ip: {127, 0, 0, 1}, startup_log: false],
        owner2
      )
      | id: :second
    })

    assert_receive {:diagnostic,
                    %{
                      event: "listener_started",
                      listener_generation: second,
                      prior_listener_generation: nil
                    }},
                   2_000

    refute first == second
    refute Enum.any?(Diagnostics.records(), &(&1.event == "listener_predecessor_stop_unknown"))
  end

  test "failed real bind emits no listener start" do
    start_supervised!({Diagnostics, notify: self()})
    owner = start_supervised!({ListenerLifecycle, name: nil})
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, active: false)
    {:ok, {_, port}} = :inet.sockname(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)

    assert {:error, bind_error} =
             start_supervised(
               ListenerLifecycle.listener_spec(
                 [plug: BoundPlug, port: port, ip: {127, 0, 0, 1}, startup_log: false],
                 owner
               )
             )

    assert inspect(bind_error) =~ "eaddrinuse"
    :sys.get_state(owner)
    assert Diagnostics.records() == []
  end

  test "production lifecycle owner is before Wakes and bound listener" do
    source = File.read!("lib/tightbeam/gateway.ex")
    [{owner, _}] = :binary.matches(source, "{Tightbeam.ListenerLifecycle, []}")
    [{wakes, _}] = :binary.matches(source, "{Tightbeam.Wakes,")
    [{listener, _}] = :binary.matches(source, "Tightbeam.ListenerLifecycle.listener_spec(")
    assert owner < wakes and wakes < listener
  end

  defp child(supervisor, id) do
    {^id, pid, _, _} = List.keyfind(Supervisor.which_children(supervisor), id, 0)
    pid
  end

  defp request(port, id) do
    {:ok, {{_, status, _}, headers, _body}} =
      :httpc.request(
        :get,
        {String.to_charlist("http://127.0.0.1:#{port}/not-found"),
         [{~c"x-tightbeam-request-id", String.to_charlist(id)}]},
        [timeout: 2_000], body_format: :binary)

    {status, headers}
  end
end
