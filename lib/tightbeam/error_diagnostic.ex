defmodule Tightbeam.ErrorDiagnostic do
  @moduledoc """
  The one optional structured diagnostic that rides beside an error's public
  `code` and `message`.

  An error keeps its existing public code, message and request/message id. When a
  boundary knows more than that — the provider's own error object, the exception
  that crashed a handler, the phase that failed, the attempt that preceded the
  last one — it attaches a diagnostic node under the single key `diagnostic`.
  A node is absent, never an empty object.

  ## Frozen shape (error-fidelity 0.1.9)

  A node is a JSON-ready map with string keys, built at the boundary that knows
  the facts. Every key is optional; a key is present only when its fact is known.
  Nothing here is manufactured: an unknown origin is absent, not guessed.

    * `"kind"` — what failed: `"jsonrpc_error"`, `"exception"`, `"exit"`,
      `"timeout"`, `"closed"`, `"http_response"`, `"decode"`, `"denial"`,
      `"unconfirmed"` (the request was sent, but nothing confirmed its effect:
      a readback that did not show the requested value, or a notification that
      is never acknowledged), `"unknown"` (the outcome is not known; the node says
      what was and was not reached), `"cleanup"` (a best-effort teardown and
      whether it was confirmed), `"throw"` or `"term"` (any other native reason).
    * `"operation"`, `"phase"`, `"origin"` — the operation, the step within it
      and the component that produced the failure.
    * `"reason"` — the original reason as a typed term (below). A decoded provider
      error object passes through verbatim, unknown fields included.
    * `"exception"` — `{"type", "message", "stacktrace", "framesOmitted"}`.
      Frames render without call arguments, so a crash never echoes the values
      it was called with.
    * `"details"` — structured fields a denial already carried beyond code and
      message, keyed as the producer spelled them.
    * `"cause"` — the node this failure was caused by; `"attempts"` — earlier
      failures of the same operation, oldest first, that the final outcome
      replaced but did not undo.
    * `"cleanup"` — the teardown a failed operation attempted, as a `cleanup`
      node whose `"status"` is `"verified"` or `"unverified"`.
    * Context keys a boundary adds (`"configId"`, `"value"`, `"exitStatus"`,
      `"status"`, `"sessionId"`, ...) in camelCase.

  ## Typed terms

  JSON values render as themselves. Everything else is wrapped with a `"$type"`
  discriminator so the representation says what was lost:

    * `{"$type": "atom", "value"}`, `{"$type": "tuple", "items"}`
    * `{"$type": "pid" | "reference" | "port" | "function", "inspect"}`
    * `{"$type": "binary", "base64"}` for bytes that are not UTF-8
    * `{"$type": "struct", "module", "fields"}`
    * `{"$type": "map", "entries": [[key, value], ...]}` for a map whose keys are
      not all strings/atoms, whose atom and string keys collide, or which itself
      carries a `"$type"` key
    * `{"$type": "truncated_string", "prefix", "bytes"}` past 8192 bytes
    * `{"$type": "omitted", "reason": "depth_limit" | "list_limit", "count"?}`

  An atom map key renders as its name.

  ## Redaction

  Secrets are replaced, never dropped, with the marker `[REDACTED:<reason>]` so
  the omission is identifiable. A field named like a secret (token,
  authorization, password, secret, api key, cookie, private key, credential)
  keeps its key and loses its value. Inside text — messages, echoed bodies,
  stack-free exception messages — bearer tokens, URL userinfo, `key=value` /
  `key: value` secrets, private key blocks and known token prefixes are
  replaced in place, leaving the surrounding text and layout intact. Redaction
  runs before truncation so a cut can never expose a partial secret.
  """

  @max_string_bytes 8192
  @max_list_items 100
  @max_depth 12
  @max_frames 40

  @secret_field_exact ~w(token authorization proxyauthorization password passwd secret
                         apikey xapikey cookie setcookie credential credentials privatekey)
  @secret_field_suffixes ~w(token secret password apikey privatekey)

  @secret_assignment ~r/\b((?:proxy[-_]?)?authorization|x[-_]api[-_]key|api[-_]?key|access[-_]?token|refresh[-_]?token|id[-_]?token|client[-_]?secret|private[-_]?key|token|password|passwd|secret|cookie)(["']?\s*[:=]\s*)((?:bearer|basic|token)\s+[^\s,;"'&}\]]+|"(?:[^"\\]|\\.)*"|'[^']*'|[^\s,;&}\]"']+)/i

  @type t :: %{optional(String.t()) => term()}

  @doc """
  Build a node of `kind` from a keyword list or map of known facts. `nil` facts
  are omitted. `:reason` is typed and redacted; `:cause` and `:attempts` must
  already be nodes (or nil / empty and then omitted). Any other key whose value
  is `{:node, node}` nests that node verbatim.
  """
  @spec new(String.t(), keyword() | map()) :: t()
  def new(kind, facts \\ []) when is_binary(kind) do
    Enum.reduce(facts, %{"kind" => kind}, fn
      {_key, nil}, node -> node
      {:attempts, []}, node -> node
      {:reason, reason}, node -> Map.put(node, "reason", encode_term(reason))
      {:cause, cause}, node when is_map(cause) -> Map.put(node, "cause", cause)
      {:attempts, list}, node when is_list(list) -> Map.put(node, "attempts", list)
      {key, {:node, nested}}, node when is_map(nested) -> Map.put(node, camel(key), nested)
      {key, value}, node -> Map.put(node, camel(key), encode_term(value))
    end)
  end

  @doc """
  Build a node from a native failure reason whose shape is not known in
  advance. A JSON-RPC error object becomes `jsonrpc_error`, an exception
  becomes `exception` (without a stack: only a rescue site has one), `:timeout`
  and `:closed` keep their meaning, and anything else is a typed `term`.
  """
  @spec from_reason(term(), keyword()) :: t()
  def from_reason(reason, facts \\ [])

  def from_reason(%{__exception__: true} = exception, facts),
    do: exception(exception, nil, facts)

  def from_reason(%{"code" => _} = error, facts),
    do: new("jsonrpc_error", Keyword.put(facts, :reason, error))

  def from_reason(%{"message" => _} = error, facts),
    do: new("jsonrpc_error", Keyword.put(facts, :reason, error))

  def from_reason(:timeout, facts), do: new("timeout", facts)
  def from_reason(:closed, facts), do: new("closed", facts)

  def from_reason({:closed, status}, facts) when is_integer(status),
    do: new("closed", Keyword.put(facts, :exit_status, status))

  def from_reason({:exit, reason}, facts),
    do: new("exit", Keyword.put(facts, :reason, reason))

  def from_reason(reason, facts), do: new("term", Keyword.put(facts, :reason, reason))

  @doc """
  Build an `exception` node. `stacktrace` is the `__STACKTRACE__` of the rescue
  site, or nil when none was captured (then the key is absent, not empty).
  """
  @spec exception(Exception.t(), Exception.stacktrace() | nil, keyword()) :: t()
  def exception(exception, stacktrace, facts \\ []) do
    detail =
      %{
        "type" => inspect(exception.__struct__),
        "message" => exception |> safe_message() |> text()
      }
      |> put_stacktrace(stacktrace)

    "exception" |> new(facts) |> Map.put("exception", detail)
  end

  @doc """
  Build a node for a caught `kind, reason` pair (`:throw` / `:exit` / `:error`)
  with the rescue site's stacktrace.
  """
  @spec caught(atom(), term(), Exception.stacktrace() | nil, keyword()) :: t()
  def caught(:error, reason, stacktrace, facts),
    do: exception(Exception.normalize(:error, reason, stacktrace || []), stacktrace, facts)

  def caught(kind, reason, stacktrace, facts) do
    kind
    |> Atom.to_string()
    |> new(Keyword.put(facts, :reason, reason))
    |> Map.merge(put_stacktrace(%{}, stacktrace))
  end

  @doc """
  Build a `decode` node from a `JSON.decode/1` error, or from
  `{:not_object, value}` when the JSON parsed but was not the object the
  boundary requires. The byte offset is where the parser stopped.
  """
  @spec json_decode(term(), keyword()) :: t()
  def json_decode(reason, facts \\ [])

  def json_decode({:invalid_byte, offset, byte}, facts),
    do: new("decode", facts ++ [error: "invalid_byte", byte_offset: offset, byte: byte])

  def json_decode({:unexpected_end, offset}, facts),
    do: new("decode", facts ++ [error: "unexpected_end", byte_offset: offset])

  def json_decode({:unexpected_sequence, offset, bytes}, facts),
    do:
      new("decode", facts ++ [error: "unexpected_sequence", byte_offset: offset, sequence: bytes])

  def json_decode({:not_object, value}, facts),
    do: new("decode", facts ++ [error: "not_object", found: json_type(value)])

  def json_decode(reason, facts), do: new("decode", Keyword.put(facts, :reason, reason))

  defp json_type(value) when is_list(value), do: "array"
  defp json_type(value) when is_binary(value), do: "string"
  defp json_type(value) when is_number(value), do: "number"
  defp json_type(value) when is_boolean(value), do: "boolean"
  defp json_type(nil), do: "null"
  defp json_type(_value), do: "unknown"

  @doc """
  Attach `node` under `key` (default `:diagnostic`) when there is one. A nil or
  empty node leaves the error untouched.
  """
  @spec put(map(), t() | nil, atom() | String.t()) :: map()
  def put(error, node, key \\ :diagnostic)
  def put(error, nil, _key), do: error
  def put(error, node, _key) when node == %{}, do: error
  def put(error, node, key), do: Map.put(error, key, node)

  @doc """
  The diagnostic a caller-facing error envelope carries: the error's own
  `:diagnostic`, plus any structured fields beyond code/message/ok as
  `"details"`. Nil when there is nothing beyond code and message.
  """
  @spec for_error(map()) :: t() | nil
  def for_error(error) when is_map(error) do
    node = Map.get(error, :diagnostic) || Map.get(error, "diagnostic")

    extras =
      Map.drop(error, [:code, :message, :ok, :diagnostic, "code", "message", "ok", "diagnostic"])

    cond do
      map_size(extras) == 0 -> node
      is_map(node) -> Map.put_new(node, "details", encode_term(extras))
      true -> %{"kind" => "denial", "details" => encode_term(extras)}
    end
  end

  @doc """
  Wrap a failure reason with its diagnostic node without changing what the
  failure means. `reason` is exactly the term the code returned before the
  diagnostic existed; every branch that decides retry, fallback or cleanup
  matches `classified/1` of the carrier and so takes the branch it always took.
  """
  @spec diagnosed(term(), t() | nil) :: term()
  def diagnosed(reason, nil), do: reason

  def diagnosed({:diagnosed, reason, prior}, node),
    do: {:diagnosed, reason, Map.put_new(node, "cause", prior)}

  def diagnosed(reason, node) when is_map(node), do: {:diagnosed, reason, node}

  @doc """
  The classification a carrier-bearing term had before diagnostics: every
  `{:diagnosed, reason, node}` inside tuples, lists and map values is replaced by
  its `reason`. Terms without carriers are returned unchanged.
  """
  @spec classified(term()) :: term()
  def classified({:diagnosed, reason, node}) when is_map(node), do: classified(reason)

  def classified(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&classified/1) |> List.to_tuple()

  def classified(term) when is_list(term) do
    if List.improper?(term), do: term, else: Enum.map(term, &classified/1)
  end

  def classified(%{__struct__: _} = term), do: term
  def classified(term) when is_map(term), do: Map.new(term, fn {k, v} -> {k, classified(v)} end)
  def classified(term), do: term

  @doc "The outermost diagnostic node a term carries, or nil."
  @spec of(term()) :: t() | nil
  def of({:diagnosed, _reason, node}) when is_map(node), do: node

  def of(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.find_value(&of/1)

  def of(term) when is_list(term) do
    if List.improper?(term), do: nil, else: Enum.find_value(term, &of/1)
  end

  def of(%{__struct__: _}), do: nil
  def of(term) when is_map(term), do: term |> Map.values() |> Enum.find_value(&of/1)
  def of(_term), do: nil

  @doc """
  The diagnostic for a failure reason reaching a caller: the carried node when
  there is one; nil for a bare classification atom (its code already says all
  that is known); otherwise a node built from the native reason.
  """
  @spec for_reason(term(), keyword()) :: t() | nil
  def for_reason(reason, facts \\ []) do
    case of(reason) do
      nil when is_atom(reason) -> nil
      nil -> from_reason(classified(reason), facts)
      node -> Enum.reduce(facts, node, fn {k, v}, acc -> put_new_fact(acc, k, v) end)
    end
  end

  @doc """
  Merge boundary facts into the node a failure already carries, or build one
  from the native reason. Facts the carried node already states win: the
  innermost boundary knew them first-hand.
  """
  @spec with_facts(term(), keyword()) :: t()
  def with_facts(reason, facts) do
    case of(reason) do
      nil -> from_reason(classified(reason), facts)
      node -> Enum.reduce(facts, node, fn {k, v}, acc -> put_new_fact(acc, k, v) end)
    end
  end

  defp put_new_fact(node, _key, nil), do: node
  defp put_new_fact(node, key, {:node, nested}), do: Map.put_new(node, camel(key), nested)
  defp put_new_fact(node, key, value), do: Map.put_new(node, camel(key), encode_term(value))

  @doc "Render any term as a JSON-ready, redacted typed value."
  @spec encode_term(term()) :: term()
  def encode_term(term), do: encode(term, 0)

  @doc "Replace secrets inside free text, keeping everything else in place."
  @spec redact_text(String.t()) :: String.t()
  def redact_text(text) when is_binary(text) do
    text
    |> String.replace(
      ~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)/s,
      "[REDACTED:private_key]"
    )
    |> then(
      &Regex.replace(@secret_assignment, &1, fn _all, key, sep, value ->
        key <> sep <> mask_value(value)
      end)
    )
    |> String.replace(~r/\b(bearer)(\s+)[A-Za-z0-9._~+\/-]{12,}=*/i, "\\1\\2[REDACTED:token]")
    |> String.replace(
      ~r{\b([a-zA-Z][a-zA-Z0-9+.-]*://)[^/\s:@\[]+(?::[^/\s@]*)?@},
      "\\1[REDACTED:userinfo]@"
    )
    |> String.replace(
      ~r/\b(?:github_pat_|gh[opusr]_|sk-|sk_|xox[abprs]-|tbc_|tbs_|tbt_|tbp_)[A-Za-z0-9_-]{8,}/,
      "[REDACTED:token]"
    )
  end

  # A quoted value keeps its quotes and an auth scheme keeps its name, so an
  # echoed JSON body or header line keeps its layout around the marker.
  defp mask_value(<<quote, _rest::binary>>) when quote in [?", ?'],
    do: <<quote>> <> "[REDACTED:secret_field]" <> <<quote>>

  defp mask_value(value) do
    case Regex.run(~r/\A(bearer|basic|token)(\s+)/i, value) do
      [_, scheme, space] -> scheme <> space <> "[REDACTED:secret_field]"
      nil -> "[REDACTED:secret_field]"
    end
  end

  ## Encoding

  defp encode(_term, depth) when depth > @max_depth,
    do: %{"$type" => "omitted", "reason" => "depth_limit"}

  defp encode(term, _depth) when is_nil(term) or is_boolean(term) or is_number(term), do: term

  defp encode(term, _depth) when is_atom(term),
    do: %{"$type" => "atom", "value" => Atom.to_string(term)}

  defp encode(term, _depth) when is_binary(term), do: text(term)

  defp encode(term, _depth) when is_bitstring(term),
    do: %{"$type" => "bitstring", "inspect" => inspect(term, limit: 50)}

  defp encode(term, depth) when is_list(term) do
    if List.improper?(term) do
      %{"$type" => "improper_list", "inspect" => term |> inspect(limit: 50) |> text()}
    else
      {kept, rest} = Enum.split(term, @max_list_items)
      items = Enum.map(kept, &encode_pair_aware(&1, depth + 1))

      case length(rest) do
        0 -> items
        n -> items ++ [%{"$type" => "omitted", "reason" => "list_limit", "count" => n}]
      end
    end
  end

  defp encode(term, depth) when is_tuple(term) do
    %{"$type" => "tuple", "items" => term |> Tuple.to_list() |> encode(depth)}
  end

  defp encode(%{__struct__: module} = struct, depth) do
    fields = struct |> Map.from_struct() |> Map.delete(:__exception__)
    %{"$type" => "struct", "module" => inspect(module), "fields" => encode(fields, depth + 1)}
  end

  defp encode(term, depth) when is_map(term) do
    if object_keys?(term) do
      Map.new(term, fn {key, value} ->
        name = key_name(key)
        {name, field(name, value, depth + 1)}
      end)
    else
      entries =
        term
        |> Enum.take(@max_list_items)
        |> Enum.map(fn {key, value} ->
          [encode(key, depth + 1), field(key_name(key), value, depth + 1)]
        end)

      %{"$type" => "map", "entries" => entries}
    end
  end

  defp encode(term, _depth) when is_pid(term), do: opaque("pid", term)
  defp encode(term, _depth) when is_reference(term), do: opaque("reference", term)
  defp encode(term, _depth) when is_port(term), do: opaque("port", term)
  defp encode(term, _depth) when is_function(term), do: opaque("function", term)

  # A two-element header pair (`{"authorization", "Bearer ..."}` or
  # `["Cookie", "..."]`) is a secret field even though it is not a map entry.
  defp encode_pair_aware({key, value}, depth) when is_binary(key) or is_atom(key) do
    if secret_field?(key_name(key)),
      do: %{"$type" => "tuple", "items" => [encode(key, depth), redacted("secret_field")]},
      else: encode({key, value}, depth)
  end

  defp encode_pair_aware([key, _value] = pair, depth) when is_binary(key) do
    if secret_field?(key),
      do: [encode(key, depth), redacted("secret_field")],
      else: encode(pair, depth)
  end

  defp encode_pair_aware(term, depth), do: encode(term, depth)

  defp field(name, value, depth) do
    if is_binary(name) and secret_field?(name) and not is_nil(value),
      do: redacted("secret_field"),
      else: encode(value, depth)
  end

  defp object_keys?(map) do
    keys = Map.keys(map)

    Enum.all?(keys, &(is_binary(&1) or (is_atom(&1) and not is_nil(&1) and not is_boolean(&1)))) and
      not Map.has_key?(map, "$type") and not Map.has_key?(map, :"$type") and
      length(keys) == keys |> Enum.map(&key_name/1) |> Enum.uniq() |> length()
  end

  defp key_name(key) when is_binary(key), do: key
  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(_key), do: nil

  defp secret_field?(nil), do: false

  defp secret_field?(name) do
    normalized = name |> String.downcase() |> String.replace(["-", "_", " "], "")

    normalized in @secret_field_exact or
      Enum.any?(@secret_field_suffixes, &String.ends_with?(normalized, &1))
  end

  defp text(value) do
    cond do
      not String.valid?(value) ->
        prefix = binary_part(value, 0, min(byte_size(value), @max_string_bytes))
        %{"$type" => "binary", "base64" => Base.encode64(prefix), "bytes" => byte_size(value)}

      true ->
        redacted = redact_text(value)

        if byte_size(redacted) > @max_string_bytes,
          do: %{
            "$type" => "truncated_string",
            "prefix" => utf8_prefix(redacted, @max_string_bytes),
            "bytes" => byte_size(redacted)
          },
          else: redacted
    end
  end

  # Cut on a character boundary so the prefix stays valid UTF-8.
  defp utf8_prefix(binary, limit) do
    case :unicode.characters_to_binary(binary_part(binary, 0, limit)) do
      {:incomplete, valid, _rest} -> valid
      valid when is_binary(valid) -> valid
    end
  end

  defp opaque(type, term), do: %{"$type" => type, "inspect" => inspect(term)}

  defp redacted(reason), do: "[REDACTED:#{reason}]"

  defp put_stacktrace(map, nil), do: map
  defp put_stacktrace(map, []), do: map

  defp put_stacktrace(map, stacktrace) do
    {kept, rest} = Enum.split(stacktrace, @max_frames)

    map
    |> Map.put("stacktrace", Enum.map(kept, &frame/1))
    |> then(fn map ->
      if rest == [], do: map, else: Map.put(map, "framesOmitted", length(rest))
    end)
  end

  defp frame({module, function, args, location}) when is_list(args),
    do: frame({module, function, length(args), location})

  defp frame(entry) do
    entry |> Exception.format_stacktrace_entry() |> text()
  rescue
    _ -> entry |> inspect(limit: 20) |> text()
  end

  defp safe_message(exception) do
    Exception.message(exception)
  rescue
    error -> "message unavailable: #{inspect(error.__struct__)} raised by Exception.message/1"
  end

  defp camel(key) when is_binary(key), do: key

  defp camel(key) when is_atom(key) do
    [head | tail] = key |> Atom.to_string() |> String.split("_")
    Enum.join([head | Enum.map(tail, &String.capitalize/1)])
  end
end
