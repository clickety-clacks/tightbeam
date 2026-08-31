defmodule Tightbeam.ActivationSelfGateTest do
  use ExUnit.Case, async: true

  @fixture_dir Path.expand("fixtures/activations", __DIR__)
  @pins %{
    "engineering.jsonl" => "5ade2056315401d6c0e3a1988969d0d842c348be8f50b4616dab7602e6c6a4f6",
    "marketing.jsonl" => "6408cd99b703cd4048697b9a9568e92aefe2657fe0dcdda5b9efe7927f2a6dc5",
    "biosciences.jsonl" => "8def2b1ac502bfde66c69b70e05f2284e24e14dddbecb3ee832f46b6e03e9053"
  }

  @manifest %{
    tables: ~w(activation_events),
    columns:
      ~w(seq eventId activationId kind predecessorEventId rootAssignmentId workItemId actorAssignmentId bySession byUser idempotencyKey requestSha256 payload noticeWakeId ts),
    event_kinds:
      ~w(declared authority-attached attempted observed reconciled withdrawn notice-requeued acknowledged),
    payload_names:
      ~w(ownerUserId domain correlationKey preparedInput target prior relation retry-of compensates supersedes authorizer basis decision authorityEventIds executor externalAttempt targetStateBefore attemptEventId certainty determinate indeterminate result targetStateAfter outputs evidence externalOccurredAtMs observedEventId irrecoverable reason noticedEventId acknowledgedWakeId replacesWakeId namespace id sha256 code),
    wire_fields: ~w(features),
    derived_states: ~w(declared attempted needs-reconciliation withdrawn observed),
    capabilities: ~w(activation-events-v1),
    verbs:
      ~w(activation-declare activation-authority activation-attempt activation-observe activation-reconcile activation-withdraw activation-renotify activation-ack activation-status activations),
    error_codes:
      ~w(invalid_activation_payload not_found activation_head_changed activation_transition_refused activation_assignment_refused activation_owner_refused activation_relation_refused activation_authority_refused activation_notice_refused invalid_idempotency_key idempotency_conflict capability_missing)
  }

  @forbidden_tokens ~w(engineering build production deploy release rollback marketing campaign field bioscience biosciences experiment instrument sample finance financial transaction payment settlement)

  @row_fields MapSet.new(~w(eventId kind rootAssignmentId actorAssignmentId noticeWakeId payload))
  @payload_shapes %{
    "declared" => ~w(ownerUserId domain correlationKey preparedInput target prior),
    "authority-attached" => ~w(authorizer basis decision),
    "attempted" => ~w(authorityEventIds executor externalAttempt targetStateBefore),
    "observed" =>
      ~w(attemptEventId certainty result targetStateAfter outputs evidence externalOccurredAtMs),
    "reconciled" =>
      ~w(observedEventId certainty result targetStateAfter outputs evidence externalOccurredAtMs),
    "withdrawn" => ~w(reason basis),
    "notice-requeued" => ~w(noticedEventId replacesWakeId),
    "acknowledged" => ~w(noticedEventId acknowledgedWakeId)
  }

  test "publication records three independent static fixture passes and keeps runtime pending" do
    record = publication_record()

    assert record.engineering == %{sha256: @pins["engineering.jsonl"], static: :pass}
    assert record.marketing == %{sha256: @pins["marketing.jsonl"], static: :pass}
    assert record.biosciences == %{sha256: @pins["biosciences.jsonl"], static: :pass}
    assert record.machine_vocabulary == :pass
    assert record.sibling_fact == :pass
    assert record.policy_boundary == :pass
    assert record.finance == :optional

    assert record.runtime == %{
             engineering: :pending_implementation,
             marketing: :pending_implementation,
             biosciences: :pending_implementation
           }
  end

  test "mandatory fixtures retain exact bytes, row ownership, closed payloads, and manifest names" do
    Enum.each(@pins, fn {name, expected_sha} ->
      bytes = File.read!(Path.join(@fixture_dir, name))
      assert fixture_gate(bytes, expected_sha) == :ok
    end)
  end

  test "the implementation's emitted activation vocabulary is the canonical manifest" do
    root = Path.expand("..", __DIR__)
    activation_source = File.read!(Path.join(root, "lib/tightbeam/activations.ex"))
    router_source = File.read!(Path.join(root, "lib/tightbeam/wire/router.ex"))

    assert implementation_gate(activation_source, router_source) == :ok
  end

  test "A-34 production-source vocabulary, sibling-table, policy, and fixture-byte mutants fail" do
    root = Path.expand("..", __DIR__)
    activation_source = File.read!(Path.join(root, "lib/tightbeam/activations.ex"))
    router_source = File.read!(Path.join(root, "lib/tightbeam/wire/router.ex"))

    assert {:error, {:forbidden_token, "production"}} =
             activation_source
             |> String.replace(
               "\"target\" => target,",
               "\"target\" => target,\n        \"productionTarget\" => target,",
               global: false
             )
             |> implementation_gate(router_source)

    assert {:error, {:forbidden_token, "campaign"}} =
             activation_source
             |> String.replace(
               ~S|defp kind_for_verb("activation-authority"), do: "authority-attached"|,
               ~S|defp kind_for_verb("activation-authority"), do: "campaign-launched"|,
               global: false
             )
             |> implementation_gate(router_source)

    assert {:error, {:forbidden_token, "bioscience"}} =
             implementation_gate(
               activation_source,
               String.replace(
                 router_source,
                 "activation-status activations spawn",
                 "activation-status activations bioscience-experiment spawn",
                 global: false
               )
             )

    assert {:error, :sibling_activation_table} =
             activation_source
             |> String.replace(
               "  CREATE INDEX IF NOT EXISTS activation_events_stream",
               "  CREATE TABLE production_deploy_facts (id TEXT);\n  CREATE INDEX IF NOT EXISTS activation_events_stream",
               global: false
             )
             |> implementation_gate(router_source)

    assert {:error, :policy_interpretation} =
             activation_source
             |> Kernel.<>(
               "\n# source mutant\ndefp domain_policy(decision), do: decision[\"code\"] == \"approved\"\n"
             )
             |> implementation_gate(router_source)

    assert {:error, :closed_state_changed} =
             activation_source
             |> String.replace(
               "      true ->\n        \"declared\"",
               "      true ->\n        \"authorized\"",
               global: false
             )
             |> implementation_gate(router_source)

    Enum.each(@pins, fn {name, expected_sha} ->
      bytes = File.read!(Path.join(@fixture_dir, name))
      <<first, rest::binary>> = bytes
      changed = <<Bitwise.bxor(first, 1), rest::binary>>
      assert {:error, :fixture_sha_mismatch} = fixture_gate(changed, expected_sha)
    end)
  end

  test "domain examples remain fixture data instead of substrate vocabulary" do
    root = Path.expand("..", __DIR__)

    for relative <- [
          "lib/tightbeam/activations.ex",
          "lib/tightbeam/gateway.ex",
          "lib/tightbeam/wire/router.ex",
          "cli/src/args.rs",
          "cli/src/dispatch.rs"
        ] do
      source = File.read!(Path.join(root, relative))
      refute source =~ "engineering."
      refute source =~ "marketing."
      refute source =~ "biosciences."
    end
  end

  defp publication_record do
    static =
      Enum.into(@pins, %{}, fn {name, expected_sha} ->
        bytes = File.read!(Path.join(@fixture_dir, name))
        :ok = fixture_gate(bytes, expected_sha)
        {String.to_atom(Path.rootname(name)), %{sha256: expected_sha, static: :pass}}
      end)

    :ok = machine_vocabulary_gate(@manifest)
    :ok = sibling_gate(@manifest.tables)
    :ok = policy_gate(@manifest.derived_states, [])

    Map.merge(static, %{
      machine_vocabulary: :pass,
      sibling_fact: :pass,
      policy_boundary: :pass,
      finance: :optional,
      runtime: %{
        engineering: :pending_implementation,
        marketing: :pending_implementation,
        biosciences: :pending_implementation
      }
    })
  end

  defp implementation_gate(activation_source, router_source) do
    manifest = implementation_manifest(activation_source, router_source)

    with :ok <- sibling_gate(manifest.tables),
         :ok <- source_policy_gate(activation_source, manifest.derived_states),
         :ok <- machine_vocabulary_gate(manifest),
         true <-
           normalized_manifest(manifest) == normalized_manifest(@manifest) or
             {:error, :machine_manifest_changed} do
      :ok
    end
  end

  defp implementation_manifest(activation_source, router_source) do
    table_body =
      activation_source
      |> then(
        &Regex.run(~r/CREATE TABLE IF NOT EXISTS activation_events \((.*?)\n  \);/s, &1,
          capture: :all_but_first
        )
      )
      |> List.first()

    columns =
      Regex.scan(~r/^\s+([A-Za-z][A-Za-z0-9]*)\s+(?:INTEGER|TEXT)\b/m, table_body,
        capture: :all_but_first
      )
      |> List.flatten()

    payload_keys =
      Regex.scan(~r/payload = %\{(.*?)\}/s, activation_source, capture: :all_but_first)
      |> List.flatten()
      |> Enum.flat_map(fn body ->
        Regex.scan(~r/"([A-Za-z][A-Za-z0-9]*)"\s*=>/, body, capture: :all_but_first)
        |> List.flatten()
      end)

    nested_payload_keys =
      [
        function_body(activation_source, "domain_identity"),
        function_body(activation_source, "domain_code"),
        function_body(activation_source, "resource_ref"),
        function_group_body(activation_source, "prior", "nullable_ms")
      ]
      |> Enum.flat_map(&map_keys/1)

    relations = sigil_words_attribute(activation_source, "relations")

    certainties =
      Regex.scan(~r/p\.certainty in ~w\(([^)]*)\)/, activation_source, capture: :all_but_first)
      |> List.flatten()
      |> Enum.flat_map(&String.split/1)

    event_kinds =
      Regex.scan(
        ~r/defp kind_for_verb\("[^"]+"\), do: "([^"]+)"/,
        activation_source,
        capture: :all_but_first
      )
      |> List.flatten()

    derived_states =
      activation_source
      |> function_body("derive_state")
      |> then(fn body ->
        Regex.scan(~r/(?:->|do:|else:)\s*"([^"]+)"/, body, capture: :all_but_first)
      end)
      |> List.flatten()

    router_activation_span =
      router_source
      |> then(
        &Regex.run(~r/@agent_verbs ~w\([^)]* artifacts (.*?) spawn /s, &1,
          capture: :all_but_first
        )
      )
      |> List.first()

    capabilities =
      router_source
      |> then(&Regex.run(~r/"features"\s*=>\s*\[([^]]*)\]/, &1, capture: :all_but_first))
      |> List.first()
      |> then(&Regex.scan(~r/"([^"]+)"/, &1, capture: :all_but_first))
      |> List.flatten()

    %{
      tables:
        Regex.scan(
          ~r/CREATE TABLE(?: IF NOT EXISTS)?\s+([A-Za-z][A-Za-z0-9_]*)/,
          activation_source,
          capture: :all_but_first
        )
        |> List.flatten(),
      columns: columns,
      event_kinds: event_kinds,
      payload_names:
        (payload_keys ++ nested_payload_keys ++ relations ++ certainties)
        |> Enum.reject(&(&1 in columns))
        |> Enum.uniq(),
      wire_fields: if(capabilities == [], do: [], else: ["features"]),
      derived_states: Enum.uniq(derived_states),
      capabilities: capabilities,
      verbs: String.split(router_activation_span),
      error_codes: sigil_words_attribute(activation_source, "error_codes")
    }
  end

  defp function_body(source, name) do
    source
    |> then(&Regex.run(~r/  defp #{name}\b(.*?)(?=\n  defp )/s, &1, capture: :all_but_first))
    |> List.first()
  end

  defp function_group_body(source, name, next_name) do
    source
    |> then(
      &Regex.run(~r/  defp #{name}\b(.*?)(?=\n  defp #{next_name}\b)/s, &1,
        capture: :all_but_first
      )
    )
    |> List.first()
  end

  defp map_keys(source) do
    Regex.scan(~r/"([A-Za-z][A-Za-z0-9]*)"\s*=>/, source, capture: :all_but_first)
    |> List.flatten()
  end

  defp sigil_words_attribute(source, name) do
    source
    |> then(&Regex.run(~r/@#{name} ~w\(([^)]*)\)/, &1, capture: :all_but_first))
    |> List.first()
    |> String.split()
  end

  defp normalized_manifest(manifest) do
    Map.new(manifest, fn {category, names} -> {category, Enum.sort(names)} end)
  end

  defp source_policy_gate(source, states) do
    interpreted_code? =
      Regex.match?(~r/\["code"\]\s*(?:==|!=|in\b)/, source) or
        Regex.match?(~r/%\{"code"\s*=>\s*"[^"]+"\}/, source)

    policy_gate(states, if(interpreted_code?, do: ["interpreted"], else: []))
  end

  defp fixture_gate(bytes, expected_sha) do
    with true <- bytes =~ ~r/\A[^\n]+\n\z/ or {:error, :fixture_line_shape},
         true <- sha256(bytes) == expected_sha or {:error, :fixture_sha_mismatch},
         {:ok, fixture} <- JSON.decode(bytes),
         :ok <-
           exact_keys(
             fixture,
             ~w(consumer events fixtureKind policyOwner runtimeCapture scenario)
           ),
         true <- fixture["fixtureKind"] == "static-design" or {:error, :fixture_kind},
         true <- fixture["runtimeCapture"] == "pending-implementation" or {:error, :runtime_claim},
         true <-
           (is_binary(fixture["consumer"]) and is_binary(fixture["policyOwner"]) and
              is_binary(fixture["scenario"])) or {:error, :fixture_metadata},
         :ok <- validate_fixture_events(fixture["events"]) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_fixture}
    end
  end

  defp validate_fixture_events(events) when is_list(events) do
    with true <-
           Enum.map(events, & &1["kind"]) ==
             ~w(declared authority-attached attempted observed acknowledged acknowledged) or
             {:error, :fixture_lifecycle},
         :ok <- reduce_ok(events, &validate_event/1),
         :ok <- validate_fixture_links(events) do
      :ok
    end
  end

  defp validate_fixture_events(_), do: {:error, :events_shape}

  defp validate_event(%{"kind" => kind, "payload" => payload} = event) do
    expected_row_keys =
      case kind do
        "declared" ->
          ~w(eventId kind payload rootAssignmentId)

        kind when kind in ~w(authority-attached) ->
          ~w(actorAssignmentId eventId kind payload)

        kind when kind in ~w(attempted observed) ->
          ~w(actorAssignmentId eventId kind noticeWakeId payload)

        "acknowledged" ->
          ~w(eventId kind payload)

        _ ->
          []
      end

    with true <- kind in @manifest.event_kinds or {:error, :event_kind},
         :ok <- exact_keys(event, expected_row_keys),
         true <-
           MapSet.subset?(MapSet.new(Map.keys(event)), @row_fields) or
             {:error, :row_owned_field},
         :ok <- token(event["eventId"]),
         :ok <- optional_token(event["rootAssignmentId"]),
         :ok <- optional_token(event["actorAssignmentId"]),
         :ok <- optional_token(event["noticeWakeId"]),
         :ok <- exact_keys(payload, Map.fetch!(@payload_shapes, kind)),
         true <-
           Enum.all?(Map.keys(payload), &(&1 in @manifest.payload_names)) or
             {:error, :payload_manifest},
         :ok <- validate_payload(kind, payload) do
      :ok
    end
  end

  defp validate_event(_), do: {:error, :event_shape}

  defp validate_payload("declared", payload) do
    with :ok <- token(payload["ownerUserId"]),
         :ok <- namespace(payload["domain"]),
         :ok <- token(payload["correlationKey"]),
         :ok <- resource(payload["preparedInput"], true),
         :ok <- resource(payload["target"], false),
         true <- is_nil(payload["prior"]) or is_map(payload["prior"]) or {:error, :prior} do
      :ok
    end
  end

  defp validate_payload("authority-attached", payload) do
    with :ok <- identity(payload["authorizer"]),
         :ok <- resource(payload["basis"], true),
         :ok <- code(payload["decision"]),
         do: :ok
  end

  defp validate_payload("attempted", payload) do
    with true <-
           (is_list(payload["authorityEventIds"]) and payload["authorityEventIds"] != []) or
             {:error, :authority_ids},
         :ok <- reduce_ok(payload["authorityEventIds"], &token/1),
         :ok <- identity(payload["executor"]),
         :ok <- resource(payload["externalAttempt"], false),
         :ok <- nullable_resource(payload["targetStateBefore"]),
         do: :ok
  end

  defp validate_payload("observed", payload) do
    with :ok <- token(payload["attemptEventId"]),
         true <- payload["certainty"] in ~w(determinate indeterminate) or {:error, :certainty},
         :ok <- code(payload["result"]),
         :ok <- nullable_resource(payload["targetStateAfter"]),
         true <- is_list(payload["outputs"]) or {:error, :outputs},
         :ok <- reduce_ok(payload["outputs"], &resource(&1, false)),
         :ok <- resource(payload["evidence"], true),
         true <-
           is_nil(payload["externalOccurredAtMs"]) or
             is_integer(payload["externalOccurredAtMs"]) or {:error, :occurred_at},
         do: :ok
  end

  defp validate_payload("acknowledged", payload) do
    with :ok <- token(payload["noticedEventId"]),
         :ok <- token(payload["acknowledgedWakeId"]),
         do: :ok
  end

  defp validate_fixture_links(events) do
    attempted = Enum.find(events, &(&1["kind"] == "attempted"))
    observed = Enum.find(events, &(&1["kind"] == "observed"))
    acknowledgements = Enum.filter(events, &(&1["kind"] == "acknowledged"))

    with true <-
           observed["payload"]["attemptEventId"] == attempted["eventId"] or
             {:error, :attempt_link},
         true <-
           observed["payload"]["certainty"] == "determinate" or
             {:error, :observation_certainty},
         true <-
           MapSet.new(
             Enum.map(acknowledgements, fn event ->
               {event["payload"]["noticedEventId"], event["payload"]["acknowledgedWakeId"]}
             end)
           ) ==
             MapSet.new([
               {attempted["eventId"], attempted["noticeWakeId"]},
               {observed["eventId"], observed["noticeWakeId"]}
             ]) or {:error, :acknowledgement_links} do
      :ok
    end
  end

  defp machine_vocabulary_gate(manifest) do
    manifest
    |> Map.values()
    |> List.flatten()
    |> Enum.flat_map(&tokens/1)
    |> Enum.find(&(&1 in @forbidden_tokens))
    |> case do
      nil -> :ok
      token -> {:error, {:forbidden_token, token}}
    end
  end

  defp sibling_gate(["activation_events"]), do: :ok
  defp sibling_gate(_), do: {:error, :sibling_activation_table}

  defp policy_gate(states, interpreted_domain_codes) do
    cond do
      Enum.sort(states) != Enum.sort(@manifest.derived_states) -> {:error, :closed_state_changed}
      interpreted_domain_codes != [] -> {:error, :policy_interpretation}
      true -> :ok
    end
  end

  defp tokens(name) do
    ~r/([a-z0-9])([A-Z])/
    |> Regex.replace(name, "\\1_\\2")
    |> String.downcase()
    |> String.split(~r/[^a-z]+/, trim: true)
  end

  defp exact_keys(map, keys) when is_map(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(keys), do: :ok, else: {:error, :closed_shape}
  end

  defp exact_keys(_, _), do: {:error, :closed_shape}

  defp identity(%{"namespace" => namespace, "id" => id} = value) when map_size(value) == 2 do
    with :ok <- namespace(namespace), :ok <- token(id), do: :ok
  end

  defp identity(_), do: {:error, :identity}

  defp code(%{"namespace" => namespace, "code" => value} = code) when map_size(code) == 2 do
    with :ok <- namespace(namespace), :ok <- token(value), do: :ok
  end

  defp code(_), do: {:error, :code}

  defp resource(%{"namespace" => namespace, "id" => id, "sha256" => sha} = resource, required)
       when map_size(resource) == 3 do
    valid_sha = is_binary(sha) and sha =~ ~r/\A[0-9a-f]{64}\z/

    with :ok <- namespace(namespace),
         :ok <- token(id),
         true <-
           if(required, do: valid_sha, else: is_nil(sha) or valid_sha) or
             {:error, :resource_sha},
         do: :ok
  end

  defp resource(_, _), do: {:error, :resource}
  defp nullable_resource(nil), do: :ok
  defp nullable_resource(value), do: resource(value, false)
  defp optional_token(nil), do: :ok
  defp optional_token(value), do: token(value)

  defp token(value) when is_binary(value) do
    if value =~ ~r/\A[A-Za-z0-9._:\/@+=-]{1,512}\z/, do: :ok, else: {:error, :token}
  end

  defp token(_), do: {:error, :token}

  defp namespace(value) when is_binary(value) do
    if value =~ ~r/\A[a-z0-9._-]{1,64}\z/, do: :ok, else: {:error, :namespace}
  end

  defp namespace(_), do: {:error, :namespace}

  defp reduce_ok(values, fun) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case fun.(value) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
