defmodule Tightbeam.IdentityApply.FailureNormalizerTest do
  use ExUnit.Case, async: true

  alias Tightbeam.IdentityApply.FailureNormalizer

  test "isolated V8 worker returns the published canonical surrogate and key fixtures" do
    fixtures = published_fixtures()

    Enum.each(fixtures, fn {source, expected, hash} ->
      assert FailureNormalizer.normalize_script(source) == expected
      assert :crypto.hash(:sha256, expected) |> Base.encode16(case: :lower) == hash
      assert FailureNormalizer.normalize_script(source) == expected
    end)
  end

  test "JavaScriptCore returns the same published canonical bytes twice" do
    fixtures = published_fixtures() ++ total_boundary_fixtures()
    sources = Enum.map(fixtures, &elem(&1, 0))
    actual = jsc_outputs(sources ++ sources)
    expected = Enum.map(fixtures, &elem(&1, 1))
    assert actual == expected ++ expected
  end

  test "V8 and JavaScriptCore agree on scalar, accessor, redaction, cycle, and cap fixtures" do
    fixtures = total_boundary_fixtures()
    expected = Enum.map(fixtures, &elem(&1, 1))

    assert Enum.map(fixtures, fn {source, _} -> FailureNormalizer.normalize_script(source) end) ==
             expected
  end

  test "both engines enforce the exact full-envelope byte boundary" do
    build =
      "var e1=Array(32).fill(0);" <>
        "var e2=Array.from({length:32},function(){return e1.slice();});" <>
        "var b=Array.from({length:31},function(){return e2.map(function(x){return x.slice();});});"

    sources = [
      build <> "return b;",
      build <> "b[0][0][0]=10;return b;",
      build <> "b[0][0][0]=100;return b;",
      build <> ~S|b[0][0][0]="\uD800A\uDC00";return b;|
    ]

    v8 = Enum.map(sources, &FailureNormalizer.normalize_script/1)
    assert byte_size(Enum.at(v8, 0)) == 65_535
    assert byte_size(Enum.at(v8, 1)) == 65_536

    assert Enum.at(v8, 2) ==
             ~s({"$truncation":{"kind":"bytes","originalBytes":65537,"sha256":"4c21079ce5167abd0116f92cce75038dbcfc13840b30378921b6444cf3930f3a"}})

    assert Enum.at(v8, 3) ==
             ~s({"$truncation":{"kind":"bytes","originalBytes":65571,"sha256":"0d9a0d570d0bc6a9f78a16761cb751d6a2b2cc241a61262976f2d584d9a4af9d"}})

    assert jsc_outputs(sources) == v8
  end

  defp published_fixtures do
    [
      {~S(return {details: "abc"};), ~s({"details":{"redactedString":true,"utf8Bytes":3}}),
       "21c7a82b953de3df9b2d8fcfdc11d443cba256222556c9afd044e1dc510aaf98"},
      {~S(return {details: "\uD83D\uDE00"};),
       ~s({"details":{"redactedString":true,"utf8Bytes":4}}),
       "774ec72add7e54cf96c6ad1a7df6c16ad8b7c94313787e53ed474e438c033b82"},
      {~S(return {details: "\uD800A\uDC00"};),
       ~s({"details":{"redactedString":true,"utf8Bytes":7}}),
       "5d0c66ce2fdfbbed348c0714a4018bb47123e937533f150624a34170897d18a7"},
      {~S"""
         var value = {};
         Object.defineProperties(value, {
           "code": {value: 0, enumerable: true},
           "code\uD800": {value: 1, enumerable: true},
           "\uD800": {value: 2, enumerable: true},
           "\uD83D\uDE00": {value: 3, enumerable: true},
           "\uDC00": {value: 4, enumerable: true},
           "\uFFFD": {value: 5, enumerable: true}
         });
         return value;
       """, ~s({"code":0,"$field0":1,"$field1":2,"$field2":3,"$field3":4,"$field4":5}),
       "023a9316f1cfb06509e07763ff284aecb8f9024349d1320161624d0264017142"}
    ]
  end

  defp total_boundary_fixtures do
    object_source =
      "var value = {};" <>
        Enum.map_join(0..64, "", fn n ->
          key = n |> Integer.to_string() |> String.pad_leading(2, "0")
          "Object.defineProperty(value,\"k#{key}\",{value:#{n},enumerable:true});"
        end) <>
        "return value;"

    object_expected =
      "{" <>
        Enum.map_join(0..63, ",", fn n -> ~s("$field#{n}":#{n}) end) <>
        ~s(,"$truncation":{"kind":"object-keys","omittedCount":1}})

    [
      {~S(return [-0,9007199254740992,9007199254740993,9007199254740993n,NaN,Infinity,-Infinity];),
       ~s([0,9007199254740992,9007199254740992,{"kind":"unsupported","type":"bigint"},{"kind":"unsupported","type":"number-nan"},{"kind":"unsupported","type":"number-positive-infinity"},{"kind":"unsupported","type":"number-negative-infinity"}])},
      {~S"""
         var calls = 0; var value = {};
         Object.defineProperty(value,"TOKEN",{enumerable:true,get:function(){calls+=1;throw 1;}});
         return value;
       """, ~s({"$field0":"[REDACTED]"})},
      {~S"""
         var calls = 0; var value = {};
         Object.defineProperty(value,"details",{enumerable:true,get:function(){calls+=1;throw 1;}});
         return value;
       """, ~s({"details":{"kind":"unsupported","type":"accessor"}})},
      {~S(var value={}; value.self=value; return value;),
       ~s({"$field0":{"kind":"unsupported","type":"cycle"}})},
      {~S(var value={code:7}; return {cause:value,details:value};),
       ~s({"cause":{"code":7},"details":{"code":7}})},
      {~S(return {"$truncation":0,code:1};), ~s({"$field0":0,"code":1})},
      {object_source, object_expected},
      {"return Array.from({length:33},function(_,i){return i;});",
       "[" <>
         Enum.map_join(0..31, ",", &Integer.to_string/1) <>
         ~s(,{"$truncation":{"kind":"array-members","omittedCount":1}}])},
      {~S(return [[[[[[[0,1]]]]]]];),
       ~s([[[[[[{"$truncation":{"kind":"depth","omittedCount":2}}]]]]]])},
      {"return new Date(0);", ~s({"kind":"unsupported","type":"exotic-object"})},
      {~S"""
       var value={}; value[Symbol("x")]=1; return value;
       """, ~s({"kind":"unsupported","type":"symbol-keyed-object"})}
    ]
  end

  defp jsc_outputs(sources) do
    runner = Path.expand("../scripts/identity_apply_jsc_runner.swift", __DIR__)
    normalizer = Path.expand("../priv/identity_apply/failure_normalizer.js", __DIR__)
    encoded = Enum.map(sources, &Base.encode64/1)
    {output, 0} = System.cmd("swift", [runner, normalizer | encoded])
    String.split(output, "\n", trim: true)
  end

  test "worker does not invoke accessors and distinguishes cycles from shared values" do
    assert FailureNormalizer.normalize_script(~S"""
             var calls = 0;
             var value = {};
             Object.defineProperty(value, "details", {
               enumerable: true,
               get: function () { calls += 1; throw new Error("secret"); }
             });
             value.code = calls;
             return value;
           """) ==
             ~s({"code":0,"details":{"kind":"unsupported","type":"accessor"}})

    assert FailureNormalizer.normalize_script(~S"""
             var value = {};
             value.self = value;
             return value;
           """) == ~s({"$field0":{"kind":"unsupported","type":"cycle"}})

    assert FailureNormalizer.normalize_script(~S"""
             var shared = {code: 7};
             return {cause: shared, details: shared};
           """) == ~s({"cause":{"code":7},"details":{"code":7}})
  end

  test "supervisor replaces a hung worker with the root timeout sentinel" do
    assert FailureNormalizer.normalize_script("while (true) {}", timeout: 25) ==
             FailureNormalizer.inspection_timeout()
  end
end
