defmodule Tightbeam.ModelCatalogTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Tightbeam.{Gateway, ModelCatalog}

  @fixtures Path.expand("fixtures", __DIR__)

  test "derives the full Codex effort inventory and rich metadata" do
    catalog = start_catalog(fn _token -> {:ok, fixture("anthropic_models.json")} end)

    assert Enum.map(catalog["codex"], & &1.ref) == [
             "gpt-alpha[low]",
             "gpt-alpha[max]",
             "gpt-alpha[ultra]",
             "gpt-bare"
           ]

    alpha = hd(catalog["codex"])
    assert alpha.display_name == "GPT Alpha"
    assert alpha.name == "GPT Alpha (low)"
    assert alpha.efforts == ["low", "max", "ultra"]
    assert alpha.max_input_tokens == 400_000
    assert alpha.capabilities["tool_calls"]
    assert length(catalog["codex"]) == 4
  end

  test "derives Claude efforts and metadata, with a bare ref when none are reported" do
    catalog = start_catalog(fn _token -> {:ok, fixture("anthropic_models.json")} end)

    assert Enum.map(catalog["claude"], & &1.ref) == [
             "claude-opus-4-8[low]",
             "claude-opus-4-8[high]",
             "claude-opus-4-8[max]",
             "claude-sonnet-4-6"
           ]

    opus = hd(catalog["claude"])
    assert opus.display_name == "Claude Opus 4.8"
    assert opus.efforts == ["low", "high", "max"]
    assert opus.max_input_tokens == 1_000_000
    assert opus.capabilities["thinking"] == %{"supported" => true}

    refute Enum.any?(catalog["claude"], &String.contains?(&1.ref, "1m"))
    refute Gateway.valid_model_ref?(catalog, "claude", "opus[1m]")
  end

  test "validation accepts every derived ref and rejects an absent ref" do
    catalog = start_catalog(fn _token -> {:ok, fixture("anthropic_models.json")} end)

    for {harness, models} <- catalog, model <- models do
      assert Gateway.valid_model_ref?(catalog, harness, model.ref)
    end

    refute Gateway.valid_model_ref?(catalog, "codex", "missing[high]")
  end

  test "missing token, missing cache, failed fetch, and malformed JSON degrade without crashing" do
    cases = [
      {"missing", false, fn _token -> {:ok, fixture("anthropic_models.json")} end},
      {"failed", true, fn _token -> {:error, :unreachable} end},
      {"malformed", true, fn _token -> {:ok, "not json"} end}
    ]

    for {suffix, token?, fetch} <- cases do
      base_dir = tmp_dir(suffix)
      File.mkdir_p!(Path.join([base_dir, "auth", "claude"]))

      if token? do
        File.write!(Path.join([base_dir, "auth", "claude", "oauth-token"]), "fixture-token")
      end

      name = unique_name()

      log =
        capture_log(fn ->
          start_supervised!(%{
            id: name,
            start:
              {ModelCatalog, :start_link,
               [
                 [
                   base_dir: base_dir,
                   codex_home: Path.join([base_dir, "auth", "codex"]),
                   name: name,
                   claude_fetch: fetch,
                   ttl_ms: :timer.hours(1)
                 ]
               ]}
          })

          Process.sleep(30)
          assert ModelCatalog.get(name) == %{"claude" => [], "codex" => []}
          assert Process.alive?(Process.whereis(name))
        end)

      assert log =~ "model catalog refresh failed for codex"
      assert log =~ "model catalog refresh failed for claude"
    end
  end

  test "failed asynchronous refresh retains the last-known inventory" do
    base_dir = fixture_base("last-known")
    test_pid = self()
    response = start_supervised!({Agent, fn -> {:ok, fixture("anthropic_models.json")} end})
    name = unique_name()

    fetch = fn _token ->
      send(test_pid, :claude_fetch)
      Agent.get(response, & &1)
    end

    start_supervised!(
      {ModelCatalog,
       base_dir: base_dir,
       codex_home: Path.join([base_dir, "auth", "codex"]),
       name: name,
       claude_fetch: fetch,
       ttl_ms: :timer.hours(1)}
    )

    assert_receive :claude_fetch
    initial = await_catalog(name)
    File.rm!(Path.join([base_dir, "auth", "codex", "models_cache.json"]))
    Agent.update(response, fn _ -> {:error, :unreachable} end)

    send(name, :refresh)
    assert_receive :claude_fetch
    await_refresh_finished(name)
    assert ModelCatalog.get(name) == initial
  end

  test "a refresh worker exit does not prevent a later refresh" do
    base_dir = fixture_base("worker-exit")
    response = start_supervised!({Agent, fn -> :exit end})
    name = unique_name()

    fetch = fn _token ->
      case Agent.get(response, & &1) do
        :exit -> exit(:refresh_worker_died)
        :succeed -> {:ok, fixture("anthropic_models.json")}
      end
    end

    start_supervised!(
      {ModelCatalog,
       base_dir: base_dir,
       codex_home: Path.join([base_dir, "auth", "codex"]),
       name: name,
       claude_fetch: fetch,
       ttl_ms: :timer.hours(1)}
    )

    await_refresh_finished(name)
    assert Process.alive?(Process.whereis(name))

    Agent.update(response, fn _ -> :succeed end)
    send(name, :refresh)

    assert await_catalog(name)["claude"] != []
  end

  test "fetches per-model Claude details when list capabilities omit effort" do
    base_dir = fixture_base("claude-detail")
    test_pid = self()
    name = unique_name()

    request = fn url, _token ->
      send(test_pid, {:claude_request, url})

      if String.ends_with?(url, "/claude-sonnet-4-6") do
        {:ok,
         JSON.encode!(%{
           "id" => "claude-sonnet-4-6",
           "capabilities" => %{
             "effort" => %{
               "medium" => %{"supported" => true},
               "high" => %{"supported" => true}
             }
           }
         })}
      else
        {:ok, fixture("anthropic_models.json")}
      end
    end

    start_supervised!(
      {ModelCatalog,
       base_dir: base_dir,
       codex_home: Path.join([base_dir, "auth", "codex"]),
       name: name,
       request_fun: request,
       ttl_ms: :timer.hours(1)}
    )

    catalog = await_catalog(name)

    assert_receive {:claude_request, "https://api.anthropic.com/v1/models?limit=100"}

    assert_receive {:claude_request, "https://api.anthropic.com/v1/models/claude-sonnet-4-6"}

    assert Enum.map(catalog["claude"], & &1.ref) == [
             "claude-opus-4-8[low]",
             "claude-opus-4-8[high]",
             "claude-opus-4-8[max]",
             "claude-sonnet-4-6[medium]",
             "claude-sonnet-4-6[high]"
           ]
  end

  test "a slow refresh never blocks cached readers" do
    base_dir = fixture_base("slow")
    test_pid = self()
    name = unique_name()

    fetch = fn _token ->
      send(test_pid, {:fetch_started, self()})

      receive do
        :release -> {:ok, fixture("anthropic_models.json")}
      end
    end

    start_supervised!(
      {ModelCatalog,
       base_dir: base_dir,
       codex_home: Path.join([base_dir, "auth", "codex"]),
       name: name,
       claude_fetch: fetch,
       ttl_ms: :timer.hours(1)}
    )

    assert_receive {:fetch_started, task}
    started = System.monotonic_time(:millisecond)
    catalog = ModelCatalog.get(name)
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed < 100
    assert catalog == %{"claude" => [], "codex" => []}

    send(task, :release)
    assert await_catalog(name)["claude"] != []
  end

  defp start_catalog(fetch) do
    base_dir = fixture_base("derived")
    name = unique_name()

    start_supervised!(
      {ModelCatalog,
       base_dir: base_dir,
       codex_home: Path.join([base_dir, "auth", "codex"]),
       name: name,
       claude_fetch: fetch,
       ttl_ms: :timer.hours(1)}
    )

    await_catalog(name)
  end

  defp await_catalog(name, attempts \\ 100)
  defp await_catalog(_name, 0), do: flunk("catalog refresh did not finish")

  defp await_catalog(name, attempts) do
    catalog = ModelCatalog.get(name)

    if catalog["claude"] != [] and catalog["codex"] != [] do
      catalog
    else
      Process.sleep(5)
      await_catalog(name, attempts - 1)
    end
  end

  defp await_refresh_finished(name, attempts \\ 100)
  defp await_refresh_finished(_name, 0), do: flunk("catalog refresh did not finish")

  defp await_refresh_finished(name, attempts) do
    if :sys.get_state(name).refreshing do
      Process.sleep(5)
      await_refresh_finished(name, attempts - 1)
    else
      :ok
    end
  end

  defp fixture_base(suffix) do
    base_dir = tmp_dir(suffix)
    codex_home = Path.join([base_dir, "auth", "codex"])
    claude_home = Path.join([base_dir, "auth", "claude"])
    File.mkdir_p!(codex_home)
    File.mkdir_p!(claude_home)

    File.cp!(
      Path.join(@fixtures, "models_cache.json"),
      Path.join(codex_home, "models_cache.json")
    )

    File.write!(Path.join(claude_home, "oauth-token"), "fixture-token\n")
    base_dir
  end

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp tmp_dir(suffix) do
    path =
      Path.join(
        System.tmp_dir!(),
        "model_catalog_#{suffix}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp unique_name,
    do: String.to_atom("model_catalog_#{System.unique_integer([:positive])}")
end
