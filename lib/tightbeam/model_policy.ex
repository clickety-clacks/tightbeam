defmodule Tightbeam.ModelPolicy do
  @moduledoc """
  Pure compilation and evaluation of structured model-rundown policy.

  The caller supplies raw source bytes and provenance. This module performs no file,
  identity, catalog, database, or process work.
  """

  alias Tightbeam.ModelPolicy.CanonicalJSON

  @floors ~w(closed working-set any)
  @segment ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @selection_keys ~w(harness model context effort guidance_suffix)

  @type source_input :: %{
          required(:kind) => :substrate | :kungfu,
          required(:name) => binary(),
          required(:path) => binary(),
          required(:bytes) => binary()
        }

  @type manifest_input :: %{
          required(:name) => binary(),
          required(:path) => binary(),
          required(:bytes) => binary()
        }

  @spec compile([source_input()], [manifest_input()]) :: {:ok, map()} | {:error, [map()]}
  def compile(sources, manifests \\ []) when is_list(sources) and is_list(manifests) do
    {decoded_sources, source_errors} = decode_sources(sources)
    {capsules, capsule_errors} = compile_capsules(decoded_sources)
    {uses, use_order, use_errors} = compile_uses(decoded_sources, capsules)
    {archetypes, manifest_errors} = compile_manifests(manifests, uses, capsules)

    errors = sort_errors(source_errors ++ capsule_errors ++ use_errors ++ manifest_errors)

    if errors == [] do
      projection = projection(capsules, uses, use_order, archetypes)
      canonical_json = CanonicalJSON.encode!(projection)

      {:ok,
       %{
         schema_version: 1,
         capsules: capsules,
         uses: uses,
         archetypes: archetypes,
         projection: projection,
         canonical_json: canonical_json,
         policy_sha256: sha256(canonical_json)
       }}
    else
      {:error, errors}
    end
  end

  @doc "Resolve an explicit use, or the archetype default when use is nil."
  @spec resolve(map(), binary(), binary() | nil) :: {:ok, map()} | {:error, map()}
  def resolve(snapshot, archetype_name, requested_use \\ nil) do
    with %{archetypes: archetypes, uses: uses} <- snapshot,
         %{default_use: default_use, allowed_uses: allowed_uses, rundowns: overrides} = binding <-
           Map.get(archetypes, archetype_name) do
      selected_use = if is_nil(requested_use), do: default_use, else: requested_use

      if selected_use in allowed_uses do
        rundown = Map.get(overrides, selected_use) || Map.fetch!(uses, selected_use)

        {:ok,
         %{
           archetype: binding.name,
           use: selected_use,
           floor: rundown.floor,
           models: rundown.models,
           source: rundown.source
         }}
      else
        {:error,
         %{
           code: "model_use_denied",
           archetype: binding.name,
           requested_use: selected_use,
           allowed_uses: Enum.sort(allowed_uses)
         }}
      end
    else
      _ -> {:error, %{code: "unknown_archetype", archetype: archetype_name}}
    end
  end

  @doc "Match one complete selection against an effective rundown."
  @spec match(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  def match(snapshot, rundown, selection) do
    with {:ok, complete} <- complete_selection(selection) do
      case Enum.find_index(rundown.models, &(selection_tuple(&1) == selection_tuple(complete))) do
        nil -> floor_match(snapshot.capsules, rundown, complete)
        index -> {:ok, %{selection_kind: "listed", rung: index + 1}}
      end
    end
  end

  @doc "Return the lowercase SHA-256 of raw bytes."
  @spec source_sha256(binary()) :: binary()
  def source_sha256(bytes) when is_binary(bytes), do: sha256(bytes)

  defp decode_sources(sources) do
    sources
    |> Enum.sort_by(&Map.get(&1, :path, ""))
    |> Enum.reduce({[], []}, fn input, {decoded, errors} ->
      case source_metadata(input) do
        {:ok, source} ->
          case decode_toml(source.bytes, source.path) do
            {:ok, document} ->
              source_errors = source_shape_errors(document, source)
              {decoded ++ [%{source: source, document: document}], errors ++ source_errors}

            {:error, error} ->
              {decoded, errors ++ [error]}
          end

        {:error, error} ->
          {decoded, errors ++ [error]}
      end
    end)
  end

  defp source_metadata(%{kind: kind, name: name, path: path, bytes: bytes})
       when kind in [:substrate, :kungfu] and is_binary(name) and is_binary(path) and
              is_binary(bytes) do
    expected_path =
      case kind do
        :substrate -> "guidance/preferred-models.toml"
        :kungfu -> "kungfu/#{name}/preferred-models.toml"
      end

    cond do
      kind == :substrate and name != "substrate" ->
        {:error, error(path, nil, nil, "source.name", "substrate source name must be substrate")}

      kind == :kungfu and not Regex.match?(@segment, name) ->
        {:error, error(path, nil, nil, "source.name", "Kung Fu source name is invalid")}

      path != expected_path ->
        {:error,
         error(path, nil, nil, "source.path", "source path must be #{inspect(expected_path)}")}

      true ->
        {:ok,
         %{
           kind: kind,
           name: name,
           path: path,
           bytes: bytes,
           sha256: sha256(bytes)
         }}
    end
  end

  defp source_metadata(input) do
    {:error,
     error(
       if(is_map(input), do: Map.get(input, :path, "<source>"), else: "<source>"),
       nil,
       nil,
       "source",
       "source must contain kind, name, path, and raw bytes"
     )}
  end

  defp decode_toml(bytes, path) do
    {:ok, Toml.decode!(bytes)}
  rescue
    exception -> {:error, error(path, nil, nil, "toml", Exception.message(exception))}
  end

  defp source_shape_errors(document, source) when is_map(document) do
    errors = unknown_key_errors(document, ~w(schema_version capsules uses), source, nil, nil, "")

    errors =
      if Map.get(document, "schema_version") == 1,
        do: errors,
        else: errors ++ [error(source.path, nil, nil, "schema_version", "must be the integer 1")]

    if source.kind == :kungfu and Map.has_key?(document, "capsules") do
      errors ++
        [error(source.path, nil, nil, "capsules", "Kung Fu sources cannot declare capsules")]
    else
      errors
    end
  end

  defp source_shape_errors(_document, source) do
    [error(source.path, nil, nil, "toml", "top-level TOML value must be a table")]
  end

  defp compile_capsules(decoded_sources) do
    {raw_capsules, errors} =
      Enum.reduce(decoded_sources, {[], []}, fn %{source: source, document: document},
                                                {capsules, errors} ->
        raw = Map.get(document, "capsules", [])

        if is_list(raw) do
          parsed =
            raw
            |> Enum.with_index(1)
            |> Enum.map(fn {capsule, rank} -> parse_capsule(capsule, source, rank) end)

          {capsules ++ Enum.map(parsed, &elem(&1, 0)),
           errors ++ Enum.flat_map(parsed, &elem(&1, 1))}
        else
          {capsules,
           errors ++
             [error(source.path, nil, nil, "capsules", "must be an array of tables")]}
        end
      end)

    Enum.reduce(raw_capsules, {%{}, %{}, []}, fn capsule, {by_model, nicknames, errors} ->
      errors =
        if valid_text?(capsule.model) and Map.has_key?(by_model, capsule.model) do
          errors ++
            [
              error(
                capsule.source.path,
                nil,
                capsule.rank,
                "capsules.model",
                "duplicate capsule model #{inspect(capsule.model)}"
              )
            ]
        else
          errors
        end

      errors =
        if valid_text?(capsule.nickname) and Map.has_key?(nicknames, capsule.nickname) do
          errors ++
            [
              error(
                capsule.source.path,
                nil,
                capsule.rank,
                "capsules.nickname",
                "duplicate capsule nickname #{inspect(capsule.nickname)}"
              )
            ]
        else
          errors
        end

      by_model =
        if valid_text?(capsule.model),
          do: Map.put_new(by_model, capsule.model, capsule),
          else: by_model

      nicknames =
        if valid_text?(capsule.nickname),
          do: Map.put_new(nicknames, capsule.nickname, true),
          else: nicknames

      {by_model, nicknames, errors}
    end)
    |> then(fn {by_model, _nicknames, duplicate_errors} ->
      {by_model, errors ++ duplicate_errors}
    end)
  end

  defp parse_capsule(raw, source, rank) when is_map(raw) do
    errors =
      unknown_key_errors(raw, ~w(model nickname description forms), source, nil, rank, "capsules")

    model = Map.get(raw, "model")
    nickname = Map.get(raw, "nickname")
    description = Map.get(raw, "description")
    errors = require_text(errors, model, source, nil, rank, "capsules.model", no_pipe: false)

    errors =
      if is_nil(nickname),
        do: errors,
        else:
          require_text(errors, nickname, source, nil, rank, "capsules.nickname", no_pipe: true)

    errors =
      require_text(errors, description, source, nil, rank, "capsules.description", no_pipe: false)

    forms_raw = Map.get(raw, "forms")

    {forms, errors} =
      if is_list(forms_raw) and forms_raw != [] do
        parsed =
          forms_raw
          |> Enum.with_index(1)
          |> Enum.map(fn {form, form_rank} -> parse_form(form, source, rank, form_rank) end)

        {Enum.map(parsed, &elem(&1, 0)), errors ++ Enum.flat_map(parsed, &elem(&1, 1))}
      else
        {[],
         errors ++
           [
             error(
               source.path,
               nil,
               rank,
               "capsules.forms",
               "must be a non-empty array of tables"
             )
           ]}
      end

    duplicate_form_errors =
      forms
      |> Enum.group_by(&{&1.harness, &1.context})
      |> Enum.filter(fn {_key, entries} -> length(entries) > 1 end)
      |> Enum.map(fn {{harness, context}, _entries} ->
        error(
          source.path,
          nil,
          rank,
          "capsules.forms",
          "duplicate capsule form #{inspect({harness, external_context(context)})}"
        )
      end)

    {%{
       model: model,
       nickname: nickname,
       description: description,
       forms: forms,
       source: source,
       rank: rank
     }, errors ++ duplicate_form_errors}
  end

  defp parse_capsule(_raw, source, rank) do
    {%{model: nil, nickname: nil, description: nil, forms: [], source: source, rank: rank},
     [error(source.path, nil, rank, "capsules", "entry must be a table")]}
  end

  defp parse_form(raw, source, capsule_rank, form_rank) when is_map(raw) do
    field = "capsules.forms[#{form_rank}]"

    errors =
      unknown_key_errors(raw, ~w(harness context efforts), source, nil, capsule_rank, field)

    harness = Map.get(raw, "harness")
    context_value = Map.get(raw, "context")
    efforts = Map.get(raw, "efforts")

    errors =
      require_text(errors, harness, source, nil, capsule_rank, "#{field}.harness", no_pipe: false)

    errors =
      require_text(errors, context_value, source, nil, capsule_rank, "#{field}.context",
        no_pipe: false
      )

    errors =
      if is_list(efforts) and Enum.all?(efforts, &valid_text?/1) and Enum.uniq(efforts) == efforts do
        errors
      else
        errors ++
          [
            error(
              source.path,
              nil,
              capsule_rank,
              "#{field}.efforts",
              "must contain unique non-empty strings"
            )
          ]
      end

    {%{
       harness: harness,
       context: internal_context(context_value),
       efforts: if(is_list(efforts), do: efforts, else: [])
     }, errors}
  end

  defp parse_form(_raw, source, capsule_rank, form_rank) do
    {%{harness: nil, context: nil, efforts: []},
     [
       error(
         source.path,
         nil,
         capsule_rank,
         "capsules.forms[#{form_rank}]",
         "entry must be a table"
       )
     ]}
  end

  defp compile_uses(decoded_sources, capsules) do
    {parsed_uses, errors} =
      Enum.reduce(decoded_sources, {[], []}, fn %{source: source, document: document},
                                                {uses, errors} ->
        raw = Map.get(document, "uses", [])

        if is_list(raw) do
          parsed =
            raw
            |> Enum.with_index(1)
            |> Enum.map(fn {use, rank} -> parse_use(use, source, rank, capsules) end)

          {uses ++ Enum.map(parsed, &elem(&1, 0)), errors ++ Enum.flat_map(parsed, &elem(&1, 1))}
        else
          {uses, errors ++ [error(source.path, nil, nil, "uses", "must be an array of tables")]}
        end
      end)

    Enum.reduce(parsed_uses, {%{}, [], errors}, fn use, {by_id, order, errors} ->
      if valid_text?(use.id) and Map.has_key?(by_id, use.id) do
        {by_id, order,
         errors ++
           [
             error(
               use.source.path,
               use.id,
               nil,
               "uses.id",
               "duplicate qualified use #{inspect(use.id)}"
             )
           ]}
      else
        {if(valid_text?(use.id), do: Map.put(by_id, use.id, use), else: by_id),
         if(valid_text?(use.id), do: order ++ [use.id], else: order), errors}
      end
    end)
  end

  defp parse_use(raw, source, use_rank, capsules) when is_map(raw) do
    local_id = Map.get(raw, "id")
    qualified_use = qualify(source, local_id, use_rank)

    errors =
      unknown_key_errors(raw, ~w(id title wants floor models), source, qualified_use, nil, "uses")

    errors =
      if is_binary(local_id) and Regex.match?(@segment, local_id),
        do: errors,
        else:
          errors ++
            [
              error(
                source.path,
                qualified_use,
                nil,
                "uses.id",
                "must be one canonical id segment"
              )
            ]

    errors =
      require_text(errors, Map.get(raw, "title"), source, qualified_use, nil, "uses.title",
        no_pipe: true
      )

    errors =
      require_text(errors, Map.get(raw, "wants"), source, qualified_use, nil, "uses.wants",
        no_pipe: true
      )

    floor = Map.get(raw, "floor")

    errors =
      if floor in @floors,
        do: errors,
        else:
          errors ++
            [
              error(
                source.path,
                qualified_use,
                nil,
                "uses.floor",
                "must be closed, working-set, or any"
              )
            ]

    {models, errors} =
      parse_models(Map.get(raw, "models"), source, qualified_use, capsules, errors)

    {%{
       id: qualified_use,
       title: Map.get(raw, "title"),
       wants: Map.get(raw, "wants"),
       floor: floor,
       models: models,
       source: provenance(source)
     }, errors}
  end

  defp parse_use(_raw, source, use_rank, _capsules) do
    qualified_use = qualify(source, nil, use_rank)

    {%{
       id: qualified_use,
       title: nil,
       wants: nil,
       floor: nil,
       models: [],
       source: provenance(source)
     }, [error(source.path, qualified_use, nil, "uses", "entry must be a table")]}
  end

  defp parse_models(raw, source, qualified_use, capsules, errors) do
    if is_list(raw) and raw != [] do
      parsed =
        raw
        |> Enum.with_index(1)
        |> Enum.map(fn {model, rung} ->
          parse_model(model, source, qualified_use, rung, capsules)
        end)

      models = Enum.map(parsed, &elem(&1, 0))
      errors = errors ++ Enum.flat_map(parsed, &elem(&1, 1))

      duplicate_errors =
        models
        |> Enum.group_by(&selection_tuple/1)
        |> Enum.filter(fn {_selection, entries} -> length(entries) > 1 end)
        |> Enum.flat_map(fn {_selection, [_first | duplicates]} ->
          Enum.map(duplicates, fn duplicate ->
            error(
              source.path,
              qualified_use,
              duplicate.rung,
              "models",
              "duplicate complete selection"
            )
          end)
        end)

      {models, errors ++ duplicate_errors}
    else
      {[],
       errors ++
         [error(source.path, qualified_use, nil, "models", "must be a non-empty array of tables")]}
    end
  end

  defp parse_model(raw, source, qualified_use, rung, capsules) when is_map(raw) do
    errors = unknown_key_errors(raw, @selection_keys, source, qualified_use, rung, "models")
    harness = Map.get(raw, "harness")
    model = Map.get(raw, "model")
    context = internal_context(Map.get(raw, "context", "default"))
    effort = Map.get(raw, "effort")
    suffix = Map.get(raw, "guidance_suffix")

    errors =
      require_text(errors, harness, source, qualified_use, rung, "models.harness", no_pipe: false)

    errors =
      require_text(errors, model, source, qualified_use, rung, "models.model", no_pipe: false)

    errors =
      if is_nil(suffix),
        do: errors,
        else:
          require_line(errors, suffix, source, qualified_use, rung, "models.guidance_suffix",
            no_pipe: true
          )

    selection = %{
      harness: harness,
      model: model,
      context: context,
      effort: effort,
      guidance_suffix: suffix,
      rung: rung
    }

    errors = errors ++ selection_form_errors(selection, capsules, source, qualified_use, rung)
    {selection, errors}
  end

  defp parse_model(_raw, source, qualified_use, rung, _capsules) do
    {%{harness: nil, model: nil, context: nil, effort: nil, guidance_suffix: nil, rung: rung},
     [error(source.path, qualified_use, rung, "models", "entry must be a table")]}
  end

  defp selection_form_errors(selection, capsules, source, qualified_use, rung) do
    case Map.get(capsules, selection.model) do
      nil ->
        [
          error(
            source.path,
            qualified_use,
            rung,
            "models.model",
            "does not reference a declared capsule"
          )
        ]

      capsule ->
        case Enum.find(
               capsule.forms,
               &(&1.harness == selection.harness and &1.context == selection.context)
             ) do
          nil ->
            [
              error(
                source.path,
                qualified_use,
                rung,
                "models.context",
                "does not reference one declared capsule form"
              )
            ]

          %{efforts: []} ->
            if is_nil(selection.effort),
              do: [],
              else: [
                error(
                  source.path,
                  qualified_use,
                  rung,
                  "models.effort",
                  "must be omitted for this capsule form"
                )
              ]

          %{efforts: efforts} ->
            if selection.effort in efforts,
              do: [],
              else: [
                error(
                  source.path,
                  qualified_use,
                  rung,
                  "models.effort",
                  "must name an effort admitted by this capsule form"
                )
              ]
        end
    end
  end

  defp compile_manifests(manifests, uses, capsules) do
    manifests
    |> Enum.sort_by(&Map.get(&1, :path, ""))
    |> Enum.reduce({%{}, []}, fn input, {compiled, errors} ->
      case manifest_metadata(input) do
        {:ok, manifest_source} ->
          case decode_toml(manifest_source.bytes, manifest_source.path) do
            {:ok, document} ->
              {binding, binding_errors} =
                parse_manifest(document, manifest_source, uses, capsules)

              duplicate_errors =
                if Map.has_key?(compiled, binding.name),
                  do: [error(manifest_source.path, nil, nil, "name", "duplicate archetype name")],
                  else: []

              {Map.put_new(compiled, binding.name, binding),
               errors ++ binding_errors ++ duplicate_errors}

            {:error, error} ->
              {compiled, errors ++ [error]}
          end

        {:error, error} ->
          {compiled, errors ++ [error]}
      end
    end)
  end

  defp manifest_metadata(%{name: name, path: path, bytes: bytes})
       when is_binary(name) and name != "" and is_binary(path) and is_binary(bytes) do
    {:ok, %{name: name, path: path, bytes: bytes, sha256: sha256(bytes)}}
  end

  defp manifest_metadata(input) do
    {:error,
     error(
       if(is_map(input), do: Map.get(input, :path, "<manifest>"), else: "<manifest>"),
       nil,
       nil,
       "manifest",
       "manifest must contain name, path, and raw bytes"
     )}
  end

  defp parse_manifest(document, source, uses, capsules) when is_map(document) do
    legacy_errors =
      []
      |> then(fn errors ->
        if Map.has_key?(document, "model_preferences"),
          do:
            errors ++
              [error(source.path, nil, nil, "model_preferences", "is invalid in schema 1")],
          else: errors
      end)
      |> then(fn errors ->
        defaults = Map.get(document, "defaults", %{})

        if is_map(defaults) do
          Enum.reduce(~w(model context effort), errors, fn key, acc ->
            if Map.has_key?(defaults, key),
              do:
                acc ++ [error(source.path, nil, nil, "defaults.#{key}", "is invalid in schema 1")],
              else: acc
          end)
        else
          errors
        end
      end)

    policy = Map.get(document, "model_policy")

    if is_map(policy) do
      errors =
        legacy_errors ++
          unknown_key_errors(
            policy,
            ~w(default_use allowed_uses rundowns),
            source,
            nil,
            nil,
            "model_policy"
          )

      default_use = Map.get(policy, "default_use")
      allowed_uses = Map.get(policy, "allowed_uses")

      errors =
        if is_binary(default_use),
          do: errors,
          else:
            errors ++
              [
                error(
                  source.path,
                  nil,
                  nil,
                  "model_policy.default_use",
                  "must be a qualified use id"
                )
              ]

      errors =
        if is_list(allowed_uses) and Enum.all?(allowed_uses, &is_binary/1),
          do: errors,
          else:
            errors ++
              [
                error(
                  source.path,
                  nil,
                  nil,
                  "model_policy.allowed_uses",
                  "must be an array of qualified use ids"
                )
              ]

      allowed_uses = if is_list(allowed_uses), do: allowed_uses, else: []
      count = Enum.count(allowed_uses, &(&1 == default_use))

      errors =
        if count == 1,
          do: errors,
          else:
            errors ++
              [
                error(
                  source.path,
                  nil,
                  nil,
                  "model_policy.default_use",
                  "must occur exactly once in allowed_uses"
                )
              ]

      errors =
        Enum.reduce(allowed_uses, errors, fn use, acc ->
          if Map.has_key?(uses, use),
            do: acc,
            else:
              acc ++
                [
                  error(
                    source.path,
                    use,
                    nil,
                    "model_policy.allowed_uses",
                    "does not resolve to a base use"
                  )
                ]
        end)

      {rundowns, errors} =
        parse_overrides(Map.get(policy, "rundowns", []), source, allowed_uses, capsules, errors)

      {%{
         name: source.name,
         default_use: default_use,
         allowed_uses: allowed_uses,
         rundowns: rundowns,
         source:
           provenance(%{
             kind: :archetype,
             name: source.name,
             path: source.path,
             sha256: source.sha256
           })
       }, errors}
    else
      {%{name: source.name, default_use: nil, allowed_uses: [], rundowns: %{}, source: nil},
       legacy_errors ++
         [error(source.path, nil, nil, "model_policy", "must be a table in schema 1")]}
    end
  end

  defp parse_manifest(_document, source, _uses, _capsules) do
    {%{name: source.name, default_use: nil, allowed_uses: [], rundowns: %{}, source: nil},
     [error(source.path, nil, nil, "toml", "top-level TOML value must be a table")]}
  end

  defp parse_overrides(raw, source, allowed_uses, capsules, errors) do
    if is_list(raw) do
      Enum.reduce(Enum.with_index(raw, 1), {%{}, errors}, fn {override, rank},
                                                             {compiled, errors} ->
        if is_map(override) do
          use = Map.get(override, "use")

          errors =
            errors ++
              unknown_key_errors(
                override,
                ~w(use floor models),
                source,
                use,
                rank,
                "model_policy.rundowns"
              )

          errors =
            if is_binary(use),
              do: errors,
              else:
                errors ++
                  [
                    error(
                      source.path,
                      use,
                      rank,
                      "model_policy.rundowns.use",
                      "must be a qualified use id"
                    )
                  ]

          errors =
            if use in allowed_uses,
              do: errors,
              else:
                errors ++
                  [
                    error(
                      source.path,
                      use,
                      rank,
                      "model_policy.rundowns.use",
                      "must name an allowed use"
                    )
                  ]

          floor = Map.get(override, "floor")

          errors =
            if floor in @floors,
              do: errors,
              else:
                errors ++
                  [
                    error(
                      source.path,
                      use,
                      rank,
                      "model_policy.rundowns.floor",
                      "must be closed, working-set, or any"
                    )
                  ]

          {models, errors} =
            parse_models(Map.get(override, "models"), source, use, capsules, errors)

          errors =
            if is_binary(use) and Map.has_key?(compiled, use),
              do:
                errors ++
                  [
                    error(
                      source.path,
                      use,
                      rank,
                      "model_policy.rundowns.use",
                      "duplicate override for allowed use"
                    )
                  ],
              else: errors

          rundown = %{
            id: use,
            floor: floor,
            models: models,
            source:
              provenance(%{
                kind: :archetype,
                name: source.name,
                path: source.path,
                sha256: source.sha256
              })
          }

          {if(is_binary(use), do: Map.put_new(compiled, use, rundown), else: compiled), errors}
        else
          {compiled,
           errors ++
             [error(source.path, nil, rank, "model_policy.rundowns", "entry must be a table")]}
        end
      end)
    else
      {%{},
       errors ++
         [error(source.path, nil, nil, "model_policy.rundowns", "must be an array of tables")]}
    end
  end

  defp floor_match(_capsules, %{floor: "closed"}, _selection), do: {:error, :not_blessed}

  defp floor_match(capsules, %{floor: "working-set"}, selection) do
    if capsule_selection?(capsules, selection),
      do: {:ok, %{selection_kind: "working_set_unlisted", rung: nil}},
      else: {:error, :not_blessed}
  end

  defp floor_match(_capsules, %{floor: "any", models: models}, _selection) do
    {:ok, %{selection_kind: "any_unlisted", rung: length(models) + 1}}
  end

  defp capsule_selection?(capsules, selection) do
    case Map.get(capsules, selection.model) do
      nil ->
        false

      capsule ->
        Enum.any?(capsule.forms, fn form ->
          form.harness == selection.harness and form.context == selection.context and
            ((form.efforts == [] and is_nil(selection.effort)) or selection.effort in form.efforts)
        end)
    end
  end

  defp complete_selection(selection) when is_map(selection) do
    complete = %{
      harness: field(selection, :harness),
      model: field(selection, :model),
      context: normalize_explicit_context(field(selection, :context)),
      effort: field(selection, :effort)
    }

    if valid_text?(complete.harness) and valid_text?(complete.model) and
         (is_nil(complete.context) or valid_text?(complete.context)) and
         (is_nil(complete.effort) or valid_text?(complete.effort)) do
      {:ok, complete}
    else
      {:error, :incomplete_selection}
    end
  end

  defp complete_selection(_selection), do: {:error, :incomplete_selection}

  defp projection(capsules, uses, use_order, archetypes) do
    %{
      "schemaVersion" => 1,
      "capsules" =>
        capsules
        |> Map.values()
        |> Enum.sort_by(&{&1.source.path, &1.rank})
        |> Enum.map(&capsule_projection/1),
      "uses" => Enum.map(use_order, &use_projection(Map.fetch!(uses, &1))),
      "archetypes" =>
        archetypes
        |> Map.values()
        |> Enum.sort_by(& &1.name)
        |> Enum.map(&archetype_projection/1)
    }
  end

  defp capsule_projection(capsule) do
    %{
      "model" => capsule.model,
      "description" => capsule.description,
      "forms" =>
        Enum.map(capsule.forms, fn form ->
          %{
            "harness" => form.harness,
            "context" => external_context(form.context),
            "efforts" => form.efforts
          }
        end)
    }
    |> maybe_put("nickname", capsule.nickname)
  end

  defp use_projection(use) do
    %{
      "id" => use.id,
      "title" => use.title,
      "wants" => use.wants,
      "floor" => use.floor,
      "models" => Enum.map(use.models, &model_projection/1),
      "source" => source_projection(use.source)
    }
  end

  defp archetype_projection(binding) do
    %{
      "name" => binding.name,
      "defaultUse" => binding.default_use,
      "allowedUses" => binding.allowed_uses,
      "rundowns" =>
        binding.rundowns
        |> Map.values()
        |> Enum.sort_by(& &1.id)
        |> Enum.map(fn rundown ->
          %{
            "use" => rundown.id,
            "floor" => rundown.floor,
            "models" => Enum.map(rundown.models, &model_projection/1),
            "source" => source_projection(rundown.source)
          }
        end),
      "source" => source_projection(binding.source)
    }
  end

  defp model_projection(model) do
    %{"harness" => model.harness, "model" => model.model}
    |> maybe_put("context", model.context)
    |> maybe_put("effort", model.effort)
    |> maybe_put("guidanceSuffix", model.guidance_suffix)
  end

  defp source_projection(source) do
    %{
      "sourceKind" => Atom.to_string(source.kind),
      "sourceName" => source.name,
      "sourcePath" => source.path
    }
  end

  defp provenance(source) do
    %{kind: source.kind, name: source.name, path: source.path, sha256: source.sha256}
  end

  defp qualify(%{kind: :substrate}, local_id, rank),
    do: "substrate:#{local_id || "invalid-#{rank}"}"

  defp qualify(%{kind: :kungfu, name: name}, local_id, rank),
    do: "kungfu:#{name}:#{local_id || "invalid-#{rank}"}"

  defp require_text(errors, value, source, use, rung, field, options) do
    if valid_text?(value) and single_line?(value) and
         (not options[:no_pipe] or not String.contains?(value, "|")) do
      errors
    else
      errors ++
        [
          error(
            source.path,
            use,
            rung,
            field,
            "must be a non-empty single-line string#{if options[:no_pipe], do: " without |", else: ""}"
          )
        ]
    end
  end

  defp require_line(errors, value, source, use, rung, field, options) do
    if is_binary(value) and single_line?(value) and
         (not options[:no_pipe] or not String.contains?(value, "|")) do
      errors
    else
      errors ++
        [
          error(
            source.path,
            use,
            rung,
            field,
            "must be a single-line string#{if options[:no_pipe], do: " without |", else: ""}"
          )
        ]
    end
  end

  defp unknown_key_errors(map, allowed, source, use, rung, prefix) do
    allowed = MapSet.new(allowed)

    map
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(allowed, &1))
    |> Enum.sort()
    |> Enum.map(fn key ->
      field = if prefix == "", do: key, else: "#{prefix}.#{key}"
      error(source.path, use, rung, field, "unknown field")
    end)
  end

  defp error(path, use, rung, field, message) do
    %{source_path: path, qualified_use: use, rung_rank: rung, field: field, message: message}
  end

  defp sort_errors(errors) do
    Enum.sort_by(errors, fn error ->
      {error.source_path || "", error.qualified_use || "", error.rung_rank || 0, error.field,
       error.message}
    end)
  end

  defp selection_tuple(selection),
    do: {selection.harness, selection.model, selection.context, selection.effort}

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp internal_context("default"), do: nil
  defp internal_context(context), do: context
  defp normalize_explicit_context("default"), do: nil
  defp normalize_explicit_context(context), do: context
  defp external_context(nil), do: "default"
  defp external_context(context), do: context
  defp valid_text?(value), do: is_binary(value) and value != ""
  defp single_line?(value), do: not String.contains?(value, ["\n", "\r"])
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
