defmodule Tightbeam.CursorSigningTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias Tightbeam.CursorSigning
  alias Tightbeam.CursorSigning.Error
  alias Tightbeam.Wire.Router

  setup do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-cursor-signing-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(base_dir) end)
    %{base_dir: base_dir}
  end

  test "normal loading refuses missing material until explicit first provisioning", ctx do
    assert {:error, %Error{reason: :missing_directory}} = CursorSigning.load(ctx.base_dir)

    assert :ok = CursorSigning.provision(ctx.base_dir)
    provider = CursorSigning.load!(ctx.base_dir)

    directory = Path.join(ctx.base_dir, "secrets")
    record = Path.join(directory, "rest-cursor-signing.v1")

    assert %File.Stat{type: :directory, mode: directory_mode} = File.lstat!(directory)
    assert Bitwise.band(directory_mode, 0o777) == 0o700

    assert %File.Stat{type: :regular, mode: record_mode, size: 32} = File.lstat!(record)
    assert Bitwise.band(record_mode, 0o777) == 0o600
    assert :ok = CursorSigning.validate(provider)
    before_second_provision = sign!(provider, "existing-record")

    assert {:error, %Error{reason: :already_provisioned}} =
             CursorSigning.provision(ctx.base_dir)

    assert sign!(provider, "existing-record") == before_second_provision
  end

  test "concurrent first provisioning creates exactly one complete record", ctx do
    directory = Path.join(ctx.base_dir, "secrets")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)

    results =
      1..8
      |> Enum.map(fn _ -> Task.async(fn -> CursorSigning.provision(ctx.base_dir) end) end)
      |> Task.await_many()

    assert Enum.count(results, &(&1 == :ok)) == 1

    assert Enum.count(results, fn
             {:error, %Error{reason: :already_provisioned}} -> true
             _other -> false
           end) == 7

    assert :ok = ctx.base_dir |> CursorSigning.load!() |> CursorSigning.validate()
  end

  test "restart and separate OS processes use the same current record", ctx do
    assert :ok = CursorSigning.provision(ctx.base_dir)
    first_provider = CursorSigning.load!(ctx.base_dir)
    first = sign!(first_provider, "stable-input")

    restarted_provider = CursorSigning.load!(ctx.base_dir)
    assert sign!(restarted_provider, "stable-input") == first

    external =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn -> external_signature(ctx.base_dir, "stable-input") end)
      end)
      |> Task.await_many(30_000)

    assert external == [first, first]
  end

  test "atomic rotation invalidates old signatures without a grace key", ctx do
    assert :ok = CursorSigning.provision(ctx.base_dir)
    provider = CursorSigning.load!(ctx.base_dir)
    old_signature = sign!(provider, "bound-cursor")

    assert :ok = CursorSigning.rotate(provider)
    new_signature = sign!(provider, "bound-cursor")

    refute new_signature == old_signature
    assert {:ok, false} = CursorSigning.verify(provider, "bound-cursor", old_signature)
    assert {:ok, true} = CursorSigning.verify(provider, "bound-cursor", new_signature)

    restarted_provider = CursorSigning.load!(ctx.base_dir)
    assert sign!(restarted_provider, "bound-cursor") == new_signature
    assert external_signature(ctx.base_dir, "bound-cursor") == new_signature
  end

  test "a failed rotation preserves the old complete record", ctx do
    assert :ok = CursorSigning.provision(ctx.base_dir)
    provider = CursorSigning.load!(ctx.base_dir)
    signature = sign!(provider, "preserved-cursor")
    directory = Path.join(ctx.base_dir, "secrets")

    File.chmod!(directory, 0o500)

    assert {:error, %Error{reason: :wrong_mode}} = CursorSigning.rotate(provider)

    File.chmod!(directory, 0o700)
    assert {:ok, true} = CursorSigning.verify(provider, "preserved-cursor", signature)
    assert File.ls!(directory) == ["rest-cursor-signing.v1"]
  end

  test "64 concurrent request processes observe only whole records across rotation", ctx do
    assert :ok = CursorSigning.provision(ctx.base_dir)
    provider = CursorSigning.load!(ctx.base_dir)
    before_rotation = sign!(provider, "concurrent-cursor")
    parent = self()

    tasks =
      for _ <- 1..64 do
        Task.async(fn ->
          send(parent, {:cursor_reader_ready, self()})

          receive do
            :read_cursor_material -> CursorSigning.sign(provider, "concurrent-cursor")
          end
        end)
      end

    readers =
      for _ <- 1..64 do
        assert_receive {:cursor_reader_ready, reader}
        reader
      end

    Enum.each(readers, &send(&1, :read_cursor_material))
    assert :ok = CursorSigning.rotate(provider)

    after_rotation = sign!(provider, "concurrent-cursor")
    refute after_rotation == before_rotation

    observed = Task.await_many(tasks)

    assert Enum.all?(observed, fn
             {:ok, signature} -> signature in [before_rotation, after_rotation]
             _other -> false
           end)
  end

  test "loads reject malformed, permissive, and symlink records", ctx do
    assert :ok = CursorSigning.provision(ctx.base_dir)
    record = Path.join([ctx.base_dir, "secrets", "rest-cursor-signing.v1"])

    File.write!(record, :crypto.strong_rand_bytes(31))
    File.chmod!(record, 0o600)
    assert {:error, %Error{reason: :invalid_material}} = CursorSigning.load(ctx.base_dir)

    File.write!(record, :crypto.strong_rand_bytes(32))
    File.chmod!(record, 0o640)
    assert {:error, %Error{reason: :wrong_mode}} = CursorSigning.load(ctx.base_dir)

    File.rm!(record)
    target = Path.join(ctx.base_dir, "symlink-target")
    File.write!(target, :crypto.strong_rand_bytes(32))
    File.chmod!(target, 0o600)
    File.ln_s!(target, record)

    assert {:error, %Error{reason: :invalid_material}} = CursorSigning.load(ctx.base_dir)
  end

  test "Router refuses missing and malformed provider injection before dispatch", ctx do
    assert_raise Error, "cursor signing is unavailable", fn -> Router.init(%{}) end

    assert_raise Error, "cursor signing is unavailable", fn ->
      Router.init(cursor_signing: :not_a_provider)
    end

    assert_raise Error, "cursor signing is unavailable", fn ->
      Tightbeam.Gateway.children_after_preflight(%{cursor_signing: :not_a_provider})
    end

    assert :ok = CursorSigning.provision(ctx.base_dir)
    provider = CursorSigning.load!(ctx.base_dir)

    assert %{cursor_signing: ^provider} = Router.init(cursor_signing: provider)
  end

  test "provider inspection, failures, logs, and ordinary responses redact private state", ctx do
    assert :ok = CursorSigning.provision(ctx.base_dir)
    provider = CursorSigning.load!(ctx.base_dir)

    assert inspect(provider) == "#Tightbeam.CursorSigning<...>"
    refute Exception.message(%Error{reason: :invalid_material}) =~ ctx.base_dir

    assert capture_log(fn ->
             assert {:ok, _signature} = CursorSigning.sign(provider, "private-input")
             assert {:error, %Error{}} = CursorSigning.sign(:invalid, "private-input")
           end) == ""

    response =
      conn(:get, "/version")
      |> Router.call(
        Router.init(
          cursor_signing: provider,
          handlers: %{},
          base_dir: ctx.base_dir,
          cli_token: "tbc_privacy"
        )
      )

    assert response.status == 200
    refute response.resp_body =~ ctx.base_dir
    refute response.resp_body =~ "cursor_signing"
  end

  defp sign!(provider, input) do
    {:ok, signature} = CursorSigning.sign(provider, input)
    signature
  end

  defp external_signature(base_dir, input) do
    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.flat_map(&["-pa", &1])

    script = """
    [base_dir, input] = System.argv()
    provider = Tightbeam.CursorSigning.load!(base_dir)
    {:ok, signature} = Tightbeam.CursorSigning.sign(provider, input)
    IO.binwrite(Base.encode16(signature, case: :lower))
    """

    elixir = System.find_executable("elixir") || raise "elixir is unavailable"

    {encoded, 0} =
      System.cmd(elixir, code_paths ++ ["-e", script, base_dir, input], stderr_to_stdout: true)

    Base.decode16!(encoded, case: :lower)
  end
end
