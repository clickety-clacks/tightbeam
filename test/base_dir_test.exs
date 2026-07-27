defmodule Tightbeam.BaseDirTest do
  # Mutates process env, so it must not run beside tests that read it. Uses the
  # project's global-state template rather than `async: false` directly — the
  # convention is enforced by TestCaseTest, which caught this file.
  use Tightbeam.TestCase, async: false

  alias Tightbeam.BaseDir

  setup do
    original = {System.get_env("TIGHTBEAM_BASE_DIR"), System.get_env("TIGHTBEAM_HOME")}

    on_exit(fn ->
      {base, home} = original

      if base,
        do: System.put_env("TIGHTBEAM_BASE_DIR", base),
        else: System.delete_env("TIGHTBEAM_BASE_DIR")

      if home,
        do: System.put_env("TIGHTBEAM_HOME", home),
        else: System.delete_env("TIGHTBEAM_HOME")
    end)

    System.delete_env("TIGHTBEAM_BASE_DIR")
    System.delete_env("TIGHTBEAM_HOME")
    :ok
  end

  test "TIGHTBEAM_BASE_DIR wins, which is the case that was broken" do
    # `mix tightbeam.init` read TIGHTBEAM_HOME only, so with BASE_DIR set it
    # initialized a different org than the service would boot: the identity repo
    # landed in ~/.tightbeam while the gateway ran against the requested path with
    # no repo in it, after reporting success.
    System.put_env("TIGHTBEAM_BASE_DIR", "/tmp/from-base-dir")
    System.put_env("TIGHTBEAM_HOME", "/tmp/from-home")

    assert BaseDir.resolve() == "/tmp/from-base-dir"
  end

  test "TIGHTBEAM_HOME is honoured when BASE_DIR is unset" do
    System.put_env("TIGHTBEAM_HOME", "/tmp/from-home")
    assert BaseDir.resolve() == "/tmp/from-home"
  end

  test "falls back to ~/.tightbeam when neither is set" do
    assert BaseDir.resolve() == Path.join(System.user_home!(), ".tightbeam")
    assert BaseDir.default() == Path.join(System.user_home!(), ".tightbeam")
  end

  test "exactly ONE resolver exists — the actual invariant" do
    # The defect was not one wrong lookup: it was four independent resolvers that
    # disagreed, so asserting any single one behaves correctly would not have caught
    # it. What must hold is that only one place interprets these variables.
    #
    # This reads source rather than calling functions, deliberately: the resolvers
    # were `defp`, unreachable from a test, which is part of why they drifted
    # unnoticed. A behavioural test cannot see a private duplicate; this can.
    readers =
      Path.wildcard("lib/**/*.ex")
      |> Enum.reject(&(Path.basename(&1) == "base_dir.ex"))
      |> Enum.filter(fn file ->
        source = File.read!(file)

        String.contains?(source, ~s|get_env("TIGHTBEAM_BASE_DIR")|) or
          String.contains?(source, ~s|get_env("TIGHTBEAM_HOME")|)
      end)

    assert readers == [],
           """
           base_dir must be resolved only by Tightbeam.BaseDir, but these files read \
           the environment directly: #{inspect(readers)}

           Two resolvers can disagree, and when they did, `mix tightbeam.init` \
           initialized one org while the service booted another — reporting success \
           both times. Delegate to Tightbeam.BaseDir.resolve/0 instead.
           """
  end
end
