defmodule Tightbeam.Acp.AttachmentAdapterTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.Acp.Adapter

  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z2S8AAAAASUVORK5CYII="

  # The initialize envelope is the recorded-real ACP shape from art_6422e9c1.
  # Each case changes only promptCapabilities.image, as required by the reviewed
  # acceptance matrix. The capture records whether session/prompt crossed the
  # adapter boundary.
  @fake ~S"""
  const fs = require("node:fs");
  const rl = require("node:readline").createInterface({ input: process.stdin });
  const capturePath = process.argv[2];
  const imageCapability = process.argv[3];
  const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\n");
  const capture = (m) => fs.appendFileSync(capturePath, JSON.stringify(m) + "\n");

  rl.on("line", (line) => {
    if (!line.trim()) return;
    const m = JSON.parse(line);
    if (m.method === "initialize") {
      capture(m);
      const promptCapabilities = { embeddedContext: true };
      if (imageCapability === "true") promptCapabilities.image = true;
      if (imageCapability === "false") promptCapabilities.image = false;
      return send({
        id: m.id,
        result: {
          protocolVersion: 1,
          agentCapabilities: { promptCapabilities },
          agentInfo: { name: "recorded-fixture", version: "1" }
        }
      });
    }
    if (m.method === "session/prompt") {
      capture(m);
      return send({ id: m.id, result: { stopReason: "end_turn" } });
    }
  });
  """

  test "image capability absent is retained as unsupported and sends no prompt" do
    {adapter, capture_path} = start_adapter("absent")

    assert Adapter.prompt_capabilities(adapter) == %{"embeddedContext" => true}
    assert {:error, refusal} = Adapter.prompt(adapter, "session", prompt_blocks())
    assert refusal.code == "unsupported_attachment"
    assert refusal.attachment_class == "image"
    assert prompt_requests(capture_path) == []
  end

  test "image capability false refuses before session/prompt" do
    {adapter, capture_path} = start_adapter("false")

    assert Adapter.prompt_capabilities(adapter) == %{
             "embeddedContext" => true,
             "image" => false
           }

    assert {:error,
            %{
              code: "unsupported_attachment",
              attachment_class: "image",
              message: "image attachments are unsupported by this adapter"
            }} = Adapter.prompt(adapter, "session", prompt_blocks())

    assert prompt_requests(capture_path) == []
  end

  test "image capability true forwards the complete ordered block list byte-for-byte" do
    {adapter, capture_path} = start_adapter("true")

    assert Adapter.prompt_capabilities(adapter) == %{
             "embeddedContext" => true,
             "image" => true
           }

    assert {:ok, %{stop_reason: "end_turn"}} =
             Adapter.prompt(adapter, "session", prompt_blocks())

    assert [request] = prompt_requests(capture_path)

    assert request["params"]["prompt"] == [
             %{"type" => "text", "text" => "inspect"},
             %{"type" => "image", "mimeType" => "image/png", "data" => @png_base64}
           ]
  end

  test "non-image attachment blocks remain unsupported in the image slice" do
    {adapter, capture_path} = start_adapter("true")

    assert {:error, %{code: "unsupported_attachment", attachment_class: "resource_link"}} =
             Adapter.prompt(adapter, "session", [
               %{type: "text", text: "inspect"},
               %{type: "resource_link", uri: "file:///tmp/not-enabled"}
             ])

    assert prompt_requests(capture_path) == []
  end

  defp prompt_blocks do
    [
      %{type: "text", text: "inspect"},
      %{type: "image", mimeType: "image/png", data: @png_base64}
    ]
  end

  defp start_adapter(image_capability) do
    run_dir =
      Path.join(
        System.tmp_dir!(),
        "tb-attachment-adapter-#{:os.getpid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(run_dir)
    on_exit(fn -> File.rm_rf!(run_dir) end)

    fake_path = Path.join(run_dir, "fake.js")
    capture_path = Path.join(run_dir, "capture.jsonl")
    File.write!(fake_path, @fake)

    child = %{
      id: {:attachment_adapter, System.unique_integer([:positive])},
      start:
        {Adapter, :start_link,
         [
           [
             harness: :claude,
             cmd: [System.find_executable("node"), fake_path, capture_path, image_capability],
             cwd: run_dir,
             stderr_path: Path.join(run_dir, "stderr.log")
           ]
         ]}
    }

    {start_supervised!(child), capture_path}
  end

  defp prompt_requests(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
    |> Enum.filter(&(&1["method"] == "session/prompt"))
  end
end
