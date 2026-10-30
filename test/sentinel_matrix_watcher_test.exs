defmodule Tightbeam.SentinelMatrixWatcherTest do
  use Tightbeam.TestCase, async: false

  test "posts a json-spec message with its original ID and complete body" do
    root = Path.join(System.tmp_dir!(), "sentinel-watcher-#{System.unique_integer([:positive])}")
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(root) end)

    matrix_argv = Path.join(root, "matrix-argv.json")
    post_args = Path.join(root, "post-args.json")
    credentials_path = Path.join(root, "existing-login-credentials")
    store_path = Path.join(root, "existing-login-store")

    write_executable!(
      Path.join(bin, "matrix-commander"),
      """
      #!/bin/sh
      python3 -c 'import json,os,sys; json.dump(sys.argv[1:],open(os.environ["MATRIX_ARGV"],"w"))' "$@"
      cat "$MATRIX_SAMPLE"
      exit "${MATRIX_COMMANDER_EXIT:-0}"
      """
    )

    write_executable!(
      Path.join(bin, "tightbeam"),
      """
      #!/usr/bin/env python3
      import json, os, sys
      with open(os.environ["TIGHTBEAM_POST_ARGS"], "w", encoding="utf-8") as output:
          json.dump(sys.argv[1:], output, ensure_ascii=False)
          output.write(chr(10))
      """
    )

    sample = Path.expand("fixtures/matrix-commander-message.jsonl", __DIR__)
    watcher = Path.expand("../priv/kungfu/sentinels/sentinels/matrix", __DIR__)
    python = System.find_executable("python3")
    assert is_binary(python)

    env = [
      {"PATH", bin <> ":" <> System.get_env("PATH", "")},
      {"MATRIX_COMMANDER_CREDENTIALS", credentials_path},
      {"MATRIX_COMMANDER_STORE", store_path},
      {"MATRIX_SAMPLE", sample},
      {"MATRIX_ARGV", matrix_argv},
      {"TIGHTBEAM_POST_ARGS", post_args}
    ]

    {output, status} = System.cmd(python, [watcher], env: env, stderr_to_stdout: true)

    # The sample stream ends, so the long-running watcher must report the
    # matrix-commander exit to the existing supervisor.
    assert status != 0
    assert output =~ "matrix-commander exited"
    refute File.exists?(credentials_path)
    refute File.exists?(store_path)

    assert JSON.decode!(File.read!(matrix_argv)) == [
             "--credentials",
             credentials_path,
             "--store",
             store_path,
             "--listen",
             "forever",
             "--listen-self",
             "--output",
             "json-spec"
           ]

    assert [posted_args] =
             File.read!(post_args)
             |> String.split("\n", trim: true)
             |> Enum.map(&JSON.decode!/1)

    assert posted_args == [
             "sentinel",
             "post",
             "--event",
             "sentinels/matrix/message",
             "--key",
             "$event-one:example.org",
             "--detail",
             "room=!room:example.org",
             "--detail",
             "sender=@author:example.org",
             "--detail",
             "text=first line\na=b\nsecond line"
           ]
  end

  test "malformed output fails without posting an event" do
    root =
      Path.join(
        System.tmp_dir!(),
        "sentinel-watcher-invalid-#{System.unique_integer([:positive])}"
      )

    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    on_exit(fn -> File.rm_rf!(root) end)

    sample = Path.join(root, "malformed.jsonl")
    File.write!(sample, "not-json\n")
    post_args = Path.join(root, "post-args.json")

    write_executable!(
      Path.join(bin, "matrix-commander"),
      "#!/bin/sh\ncat \"$MATRIX_SAMPLE\"\nexec sleep 60\n"
    )

    write_executable!(
      Path.join(bin, "tightbeam"),
      "#!/bin/sh\nprintf posted > \"$TIGHTBEAM_POST_ARGS\"\n"
    )

    env = [
      {"PATH", bin <> ":" <> System.get_env("PATH", "")},
      {"MATRIX_COMMANDER_CREDENTIALS", Path.join(root, "credentials-path")},
      {"MATRIX_COMMANDER_STORE", Path.join(root, "store-path")},
      {"MATRIX_SAMPLE", sample},
      {"TIGHTBEAM_POST_ARGS", post_args}
    ]

    python = System.find_executable("python3")
    watcher = Path.expand("../priv/kungfu/sentinels/sentinels/matrix", __DIR__)
    {output, status} = System.cmd(python, [watcher], env: env, stderr_to_stdout: true)

    assert status != 0
    assert output =~ "malformed JSON"
    refute File.exists?(post_args)
  end

  defp write_executable!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o755)
  end
end
