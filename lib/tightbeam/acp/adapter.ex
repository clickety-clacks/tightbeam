defmodule Tightbeam.Acp.Adapter do
  @moduledoc """
  Harness session layer over Acp.Conn. One Adapter per (harness, archetype);
  it owns a Conn and routes session/update chunks by sessionId to the turn
  currently prompting each session.

  Adapter rules (spec §Adapter selection; the SOURCE OF TRUTH mirrored from the
  TS reference harness.ts):
  1. Apply the model immediately after session/new AND session/load — never
     trust the advertised current model (the fable trap).
  2. Model via session/set_config_option {configId:"model"} with a BARE name;
     effort rides as "model[effort]" split and applied via the harness's effort
     config id.
  4. Permission requests auto-allowed by Conn (YOLO); sessions run in the
     harness's bypass mode set at session/new time.
  """

  use GenServer
  alias Tightbeam.Acp.Conn

  @type server :: GenServer.server()
  @type prompt_result :: %{stop_reason: String.t(), text: String.t()}
  @type preset :: %{
          home_env: String.t(),
          yolo_mode: String.t(),
          effort_config: String.t()
        }
  @type t :: %__MODULE__{
          conn: server(),
          preset: preset(),
          cwd: String.t(),
          chunks: %{String.t() => [String.t()]}
        }

  @presets %{
    claude: %{
      home_env: "CLAUDE_CONFIG_DIR",
      yolo_mode: "bypassPermissions",
      effort_config: "effort"
    },
    codex: %{
      home_env: "CODEX_HOME",
      yolo_mode: "agent-full-access",
      effort_config: "reasoning_effort"
    }
  }

  defstruct [:conn, :preset, :cwd, chunks: %{}]

  ## Client

  @doc "Start one harness adapter and its owned ACP connection."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @doc "Create a fresh harness session, model applied. Returns {:ok, session_id}."
  @spec new_session(server(), String.t()) :: {:ok, String.t()}
  def new_session(adapter, model), do: GenServer.call(adapter, {:new_session, model}, 30_000)

  @doc "Adopt an existing harness session (re-applies model). Returns :ok."
  @spec load_session(server(), String.t(), String.t()) :: :ok
  def load_session(adapter, session_id, model),
    do: GenServer.call(adapter, {:load_session, session_id, model}, 30_000)

  @doc "Run a turn; accumulates chunks; returns {:ok, %{stop_reason, text}}."
  @spec prompt(server(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, prompt_result()} | {:error, term()}
  def prompt(adapter, session_id, text, timeout \\ 600_000),
    do: GenServer.call(adapter, {:prompt, session_id, text}, timeout + 5_000)

  @doc "Return the ACP connection owned by this adapter."
  @spec conn(server()) :: Conn.server()
  def conn(adapter), do: GenServer.call(adapter, :conn)

  ## Server

  @doc "Initialize the ACP protocol and pin the adapter's harness preset."
  @spec init(keyword()) :: {:ok, t()}
  @impl true
  def init(opts) do
    harness = Keyword.fetch!(opts, :harness)
    preset = Map.fetch!(@presets, harness)

    {:ok, conn} =
      Conn.start_link(
        cmd: Keyword.fetch!(opts, :cmd),
        env: [{preset.home_env, Keyword.fetch!(opts, :home)}] ++ Keyword.get(opts, :env, []),
        stderr_path: Keyword.get(opts, :stderr_path, "/dev/null"),
        subscriber: self()
      )

    {:ok, %{"protocolVersion" => 1}} =
      Conn.request(conn, "initialize", %{
        protocolVersion: 1,
        clientCapabilities: %{fs: %{readTextFile: false, writeTextFile: false}}
      })

    {:ok, %__MODULE__{conn: conn, preset: preset, cwd: Keyword.fetch!(opts, :cwd)}}
  end

  @doc "Handle harness session creation, adoption, prompting, and connection lookup."
  @spec handle_call(term(), GenServer.from(), t()) ::
          {:reply, term(), t()} | {:noreply, t()}
  @impl true
  def handle_call({:new_session, model}, _from, state) do
    {:ok, result} = Conn.request(state.conn, "session/new", %{cwd: state.cwd, mcpServers: []})
    sid = result["sessionId"]
    :ok = apply_model(state, sid, model)

    _ =
      Conn.request(state.conn, "session/set_mode", %{
        sessionId: sid,
        modeId: state.preset.yolo_mode
      })

    {:reply, {:ok, sid}, put_in(state.chunks[sid], [])}
  end

  def handle_call({:load_session, sid, model}, _from, state) do
    {:ok, _} = Conn.request(state.conn, "session/load", %{sessionId: sid, cwd: state.cwd})
    :ok = apply_model(state, sid, model)
    {:reply, :ok, put_in(state.chunks[sid], [])}
  end

  def handle_call({:prompt, sid, text}, from, state) do
    state = put_in(state.chunks[sid], [])
    # Fire the ACP prompt asynchronously so this GenServer keeps routing
    # session/update chunks while the turn runs.
    parent = self()

    Task.start(fn ->
      result =
        Conn.request(
          state.conn,
          "session/prompt",
          %{sessionId: sid, prompt: [%{type: "text", text: text}]}, timeout: 600_000)

      send(parent, {:prompt_done, sid, from, result})
    end)

    {:noreply, state}
  end

  def handle_call(:conn, _from, state), do: {:reply, state.conn, state}

  @doc "Accumulate session chunks and resolve completed prompts for their waiting callers."
  @spec handle_info(term(), t()) :: {:noreply, t()}
  @impl true
  def handle_info({:acp_notification, "session/update", params}, state) do
    sid = params["sessionId"]
    update = params["update"] || %{}

    if update["sessionUpdate"] == "agent_message_chunk" do
      text = get_in(update, ["content", "text"])

      if is_binary(text) and Map.has_key?(state.chunks, sid) do
        {:noreply, update_in(state.chunks[sid], &[text | &1])}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:prompt_done, sid, from, result}, state) do
    text = state.chunks |> Map.get(sid, []) |> Enum.reverse() |> Enum.join()

    reply =
      case result do
        {:ok, r} -> {:ok, %{stop_reason: r["stopReason"] || "unknown", text: text}}
        {:error, e} -> {:error, e}
      end

    GenServer.reply(from, reply)
    {:noreply, put_in(state.chunks[sid], [])}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Model application (the fable-trap rule)

  defp apply_model(state, sid, model_ref) do
    {model, effort} = parse_model_ref(model_ref)

    {:ok, _} =
      Conn.request(state.conn, "session/set_config_option", %{
        sessionId: sid,
        configId: "model",
        value: model
      })

    if effort do
      {:ok, _} =
        Conn.request(state.conn, "session/set_config_option", %{
          sessionId: sid,
          configId: state.preset.effort_config,
          value: effort
        })
    end

    :ok
  end

  @doc """
  Split a model reference into its bare model name and optional effort.

      iex> Tightbeam.Acp.Adapter.parse_model_ref("gpt-5.6-sol[medium]")
      {"gpt-5.6-sol", "medium"}
      iex> Tightbeam.Acp.Adapter.parse_model_ref("haiku")
      {"haiku", nil}
  """
  @spec parse_model_ref(String.t()) :: {String.t(), String.t() | nil}
  def parse_model_ref(ref) do
    case Regex.run(~r/^(.*?)\[(.*?)\]$/, ref) do
      [_, model, effort] -> {model, effort}
      _ -> {ref, nil}
    end
  end
end
