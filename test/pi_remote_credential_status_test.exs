defmodule Tightbeam.PiRemoteCredentialStatusTest do
  use Tightbeam.TestCase, async: false

  test "remote Pi provider readiness reads the selected host, not local files" do
    owner = self()

    sh = fn argv ->
      assert "fixture@pi-host" in argv
      command = Enum.join(argv, " ")

      cond do
        String.contains?(command, "/bin/test -x") ->
          {"", 0}

        "-d" in argv or "-x" in argv ->
          {"", 0}

        String.contains?(command, "/bin/ls") ->
          send(owner, :remote_provider_listed)
          {"spark.json\n", 0}

        String.contains?(command, "__TIGHTBEAM_API_KEY") ->
          {~s({"name":"spark","type":"local-openai","endpoint":"http://127.0.0.1:8000/v1"}) <>
             "\n__TIGHTBEAM_API_KEY_ABSENT__\n", 0}

        true ->
          # No home metadata exists on this fixture host. Presence must still
          # come from its provider descriptor, not a gateway filesystem read.
          {"", 1}
      end
    end

    {:ok, server} =
      Tightbeam.Credentials.start_link(
        name: nil,
        base_dir: "/remote-only/pi-readiness-fixture",
        machine: "pi-host",
        ssh: "fixture@pi-host",
        sh: sh
      )

    assert :onboarded = Tightbeam.Credentials.status(:local_openai, server)
    assert_received :remote_provider_listed
    GenServer.stop(server)
  end
end
