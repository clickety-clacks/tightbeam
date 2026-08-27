defmodule Tightbeam.CursorSigningTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias Tightbeam.CursorSigning
  alias Tightbeam.CursorSigning.Error
  alias Tightbeam.Wire.Router

  @domain_separator <<"tightbeam/rest-read-plane-d1/cursor/v1", 0>>

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

  test "signing always prepends the fixed cursor domain separator", ctx do
    assert :ok = CursorSigning.provision(ctx.base_dir)
    provider = CursorSigning.load!(ctx.base_dir)
    body = "canonical-cursor-body"
    signature = sign!(provider, body)
    material = File.read!(Path.join([ctx.base_dir, "secrets", "rest-cursor-signing.v1"]))

    expected = :crypto.mac(:hmac, :sha256, material, [@domain_separator, body])
    unscoped = :crypto.mac(:hmac, :sha256, material, body)

    assert Plug.Crypto.secure_compare(signature, expected)
    refute Plug.Crypto.secure_compare(signature, unscoped)
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

  test "durable provisioning and rotation survive immediate VM termination", ctx do
    assert 137 == external_durable_operation(ctx.base_dir, "provision")

    first_provider = CursorSigning.load!(ctx.base_dir)
    old_signature = sign!(first_provider, "durable-cursor")

    assert 137 == external_durable_operation(ctx.base_dir, "rotate")

    restarted_provider = CursorSigning.load!(ctx.base_dir)
    new_signature = sign!(restarted_provider, "durable-cursor")

    refute new_signature == old_signature

    assert {:ok, false} =
             CursorSigning.verify(restarted_provider, "durable-cursor", old_signature)

    assert {:ok, true} = CursorSigning.verify(restarted_provider, "durable-cursor", new_signature)
    assert File.ls!(Path.join(ctx.base_dir, "secrets")) == ["rest-cursor-signing.v1"]
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

  test "64 request processes in two application VMs linearize across rotation", ctx do
    assert :ok = CursorSigning.provision(ctx.base_dir)
    provider = CursorSigning.load!(ctx.base_dir)
    before_rotation = sign!(provider, "concurrent-cursor")
    control_dir = Path.join(ctx.base_dir, "rotation-proof")
    File.mkdir_p!(control_dir)

    applications =
      for application_id <- ["one", "two"] do
        Task.async(fn ->
          external_concurrency_summary(ctx.base_dir, control_dir, application_id)
        end)
      end

    await_marker_count!(control_dir, "ready-", 64)
    File.write!(Path.join(control_dir, "go"), "")
    await_marker_count!(control_dir, "pre-", 64)

    File.write!(Path.join(control_dir, "rotating"), "")
    await_marker_count!(control_dir, "during-", 64)
    assert :ok = CursorSigning.rotate(provider)
    File.write!(Path.join(control_dir, "post"), "")
    await_marker_count!(control_dir, "post-", 64)
    File.write!(Path.join(control_dir, "stop"), "")

    after_rotation = sign!(provider, "concurrent-cursor")
    refute after_rotation == before_rotation

    summaries = Task.await_many(applications, 30_000)

    assert Enum.sum(Enum.map(summaries, & &1.workers)) == 64
    assert summaries |> Enum.map(& &1.os_pid) |> Enum.uniq() |> length() == 2

    assert Enum.all?(summaries, fn summary ->
             summary.workers == 32 and
               summary.pre >= 32 and
               summary.during >= 32 and
               summary.post >= 32 and
               summary.old > 0 and
               summary.new > 0 and
               summary.invalid == 0
           end)

    assert {:ok, false} = CursorSigning.verify(provider, "concurrent-cursor", before_rotation)
    assert {:ok, true} = CursorSigning.verify(provider, "concurrent-cursor", after_rotation)
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

    File.chmod!(record, 0o4600)
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
    script = """
    [base_dir, input] = System.argv()
    provider = Tightbeam.CursorSigning.load!(base_dir)
    {:ok, signature} = Tightbeam.CursorSigning.sign(provider, input)
    IO.binwrite(Base.encode16(signature, case: :lower))
    """

    {encoded, 0} = external_elixir(script, [base_dir, input])

    Base.decode16!(encoded, case: :lower)
  end

  defp external_durable_operation(base_dir, operation) do
    script = """
    [base_dir, operation] = System.argv()

    case operation do
      "provision" ->
        :ok = Tightbeam.CursorSigning.provision(base_dir)

      "rotate" ->
        provider = Tightbeam.CursorSigning.load!(base_dir)
        :ok = Tightbeam.CursorSigning.rotate(provider)
    end

    System.halt(137)
    """

    {"", status} = external_elixir(script, [base_dir, operation])
    status
  end

  defp external_concurrency_summary(base_dir, control_dir, application_id) do
    script = """
    defmodule CursorSigningConcurrencyProbe do
      @workers 32

      def run(base_dir, control_dir, application_id) do
        provider = Tightbeam.CursorSigning.load!(base_dir)
        old_signature = sign!(provider)

        tasks =
          for index <- 1..@workers do
            Task.async(fn -> worker(provider, control_dir, application_id, index) end)
          end

        samples = tasks |> Task.await_many(30_000) |> List.flatten()
        new_signature = sign!(provider)

        summary =
          Enum.reduce(samples, initial_summary(application_id), fn sample, summary ->
            classify(sample, old_signature, new_signature, summary)
          end)

        IO.binwrite(summary |> :erlang.term_to_binary() |> Base.encode64())
      end

      defp worker(provider, control_dir, application_id, index) do
        File.write!(marker(control_dir, "ready", application_id, index), "")
        await_file(Path.join(control_dir, "go"), 15_000)
        collect(provider, control_dir, application_id, index, [])
      end

      defp collect(provider, control_dir, application_id, index, samples) do
        before_phase = phase(control_dir)
        signature = sign!(provider)
        after_phase = phase(control_dir)

        mark_phase(control_dir, application_id, index, before_phase, after_phase)
        samples = [{before_phase, after_phase, signature} | samples]

        if File.exists?(Path.join(control_dir, "stop")) do
          samples
        else
          Process.sleep(1)
          collect(provider, control_dir, application_id, index, samples)
        end
      end

      defp phase(control_dir) do
        cond do
          File.exists?(Path.join(control_dir, "post")) -> :post
          File.exists?(Path.join(control_dir, "rotating")) -> :during
          true -> :pre
        end
      end

      defp mark_phase(control_dir, application_id, index, phase, phase)
           when phase in [:pre, :during, :post] do
        path = marker(control_dir, Atom.to_string(phase), application_id, index)

        unless File.exists?(path) do
          File.write!(path, "")
        end
      end

      defp mark_phase(_control_dir, _application_id, _index, _before, _after), do: :ok

      defp marker(control_dir, phase, application_id, index) do
        name = Enum.join([phase, application_id, Integer.to_string(index)], "-")
        Path.join(control_dir, name)
      end

      defp await_file(_path, 0), do: raise("cursor concurrency barrier timed out")

      defp await_file(path, attempts) do
        if File.exists?(path) do
          :ok
        else
          Process.sleep(2)
          await_file(path, attempts - 1)
        end
      end

      defp sign!(provider) do
        {:ok, signature} = Tightbeam.CursorSigning.sign(provider, "concurrent-cursor")
        signature
      end

      defp initial_summary(application_id) do
        %{
          application: application_id,
          os_pid: System.pid(),
          workers: @workers,
          pre: 0,
          during: 0,
          post: 0,
          old: 0,
          new: 0,
          invalid: 0
        }
      end

      defp classify({before_phase, after_phase, signature}, old, new, summary) do
        phase =
          cond do
            before_phase == :pre and after_phase == :pre -> :pre
            before_phase == :post and after_phase == :post -> :post
            true -> :during
          end

        valid =
          case phase do
            :pre -> signature == old
            :post -> signature == new
            :during -> signature == old or signature == new
          end

        generation = if signature == old, do: :old, else: :new

        summary
        |> Map.update!(phase, &(&1 + 1))
        |> Map.update!(generation, &(&1 + 1))
        |> then(fn summary ->
          if valid, do: summary, else: Map.update!(summary, :invalid, &(&1 + 1))
        end)
      end
    end

    [base_dir, control_dir, application_id] = System.argv()
    CursorSigningConcurrencyProbe.run(base_dir, control_dir, application_id)
    """

    {encoded, 0} = external_elixir(script, [base_dir, control_dir, application_id])

    encoded
    |> Base.decode64!()
    |> :erlang.binary_to_term([:safe])
  end

  defp await_marker_count!(control_dir, prefix, expected, attempts \\ 1_000)

  defp await_marker_count!(_control_dir, _prefix, _expected, 0) do
    raise "cursor concurrency marker timeout"
  end

  defp await_marker_count!(control_dir, prefix, expected, attempts) do
    count =
      control_dir
      |> File.ls!()
      |> Enum.count(&String.starts_with?(&1, prefix))

    if count == expected do
      :ok
    else
      Process.sleep(10)
      await_marker_count!(control_dir, prefix, expected, attempts - 1)
    end
  end

  defp external_elixir(script, arguments) do
    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.flat_map(&["-pa", &1])

    elixir = System.find_executable("elixir") || raise "elixir is unavailable"

    System.cmd(elixir, code_paths ++ ["-e", script | arguments], stderr_to_stdout: true)
  end
end
