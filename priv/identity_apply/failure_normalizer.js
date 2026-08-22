(function (root) {
  "use strict";

  var NODE_BUDGET = 65536;
  var BYTE_LIMIT = 65536;
  var OBJECT_LIMIT = 64;
  var ARRAY_LIMIT = 32;
  var DEPTH_LIMIT = 6;

  var preservedNames = Object.create(null);
  [
    "name", "code", "status", "statusCode", "exitCode", "signal",
    "timedOut", "cause", "errors", "details", "kind", "type"
  ].forEach(function (name) { preservedNames[name] = true; });

  var secretNames = Object.create(null);
  [
    "token", "secret", "password", "authorization", "cookie", "set-cookie",
    "api-key", "api_key", "credential", "private-key", "private_key"
  ].forEach(function (name) { secretNames[name] = true; });

  function sentinel(type) {
    return {kind: "unsupported", type: type};
  }

  function toWellFormed(value) {
    var result = "";
    for (var i = 0; i < value.length; i += 1) {
      var unit = value.charCodeAt(i);
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (i + 1 < value.length) {
          var low = value.charCodeAt(i + 1);
          if (low >= 0xDC00 && low <= 0xDFFF) {
            result += value.charAt(i) + value.charAt(i + 1);
            i += 1;
            continue;
          }
        }
        result += "\uFFFD";
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        result += "\uFFFD";
      } else {
        result += value.charAt(i);
      }
    }
    return result;
  }

  function isWellFormed(value) {
    for (var i = 0; i < value.length; i += 1) {
      var unit = value.charCodeAt(i);
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (i + 1 >= value.length) return false;
        var low = value.charCodeAt(i + 1);
        if (low < 0xDC00 || low > 0xDFFF) return false;
        i += 1;
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        return false;
      }
    }
    return true;
  }

  function asciiFold(value) {
    var result = "";
    for (var i = 0; i < value.length; i += 1) {
      var unit = value.charCodeAt(i);
      if (unit >= 0x41 && unit <= 0x5A) unit += 0x20;
      result += String.fromCharCode(unit);
    }
    return result;
  }

  function utf8Bytes(value) {
    var count = 0;
    for (var i = 0; i < value.length; i += 1) {
      var unit = value.charCodeAt(i);
      if (unit <= 0x7F) {
        count += 1;
      } else if (unit <= 0x7FF) {
        count += 2;
      } else if (unit >= 0xD800 && unit <= 0xDBFF) {
        count += 4;
        i += 1;
      } else {
        count += 3;
      }
    }
    return count;
  }

  function utf8(value) {
    var bytes = [];
    for (var i = 0; i < value.length; i += 1) {
      var unit = value.charCodeAt(i);
      var scalar = unit;
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        var low = value.charCodeAt(i + 1);
        scalar = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
        i += 1;
      }
      if (scalar <= 0x7F) {
        bytes.push(scalar);
      } else if (scalar <= 0x7FF) {
        bytes.push(0xC0 | (scalar >> 6), 0x80 | (scalar & 0x3F));
      } else if (scalar <= 0xFFFF) {
        bytes.push(
          0xE0 | (scalar >> 12),
          0x80 | ((scalar >> 6) & 0x3F),
          0x80 | (scalar & 0x3F)
        );
      } else {
        bytes.push(
          0xF0 | (scalar >> 18),
          0x80 | ((scalar >> 12) & 0x3F),
          0x80 | ((scalar >> 6) & 0x3F),
          0x80 | (scalar & 0x3F)
        );
      }
    }
    return bytes;
  }

  function rightRotate(value, amount) {
    return (value >>> amount) | (value << (32 - amount));
  }

  function sha256(value) {
    var bytes = utf8(value);
    var bitLength = bytes.length * 8;
    bytes.push(0x80);
    while ((bytes.length % 64) !== 56) bytes.push(0);
    var high = Math.floor(bitLength / 0x100000000);
    var low = bitLength >>> 0;
    for (var shift = 24; shift >= 0; shift -= 8) bytes.push((high >>> shift) & 0xFF);
    for (var shift2 = 24; shift2 >= 0; shift2 -= 8) bytes.push((low >>> shift2) & 0xFF);

    var h = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ];
    var k = [
      0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
      0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
      0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
      0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
      0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
      0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
      0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
      0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    ];

    for (var offset = 0; offset < bytes.length; offset += 64) {
      var w = new Array(64);
      for (var j = 0; j < 16; j += 1) {
        var at = offset + j * 4;
        w[j] = ((bytes[at] << 24) | (bytes[at + 1] << 16) |
          (bytes[at + 2] << 8) | bytes[at + 3]) >>> 0;
      }
      for (var j2 = 16; j2 < 64; j2 += 1) {
        var s0 = rightRotate(w[j2 - 15], 7) ^ rightRotate(w[j2 - 15], 18) ^ (w[j2 - 15] >>> 3);
        var s1 = rightRotate(w[j2 - 2], 17) ^ rightRotate(w[j2 - 2], 19) ^ (w[j2 - 2] >>> 10);
        w[j2] = (w[j2 - 16] + s0 + w[j2 - 7] + s1) >>> 0;
      }

      var a=h[0], b=h[1], c=h[2], d=h[3], e=h[4], f=h[5], g=h[6], hh=h[7];
      for (var round = 0; round < 64; round += 1) {
        var upper = rightRotate(e,6) ^ rightRotate(e,11) ^ rightRotate(e,25);
        var choose = (e & f) ^ ((~e) & g);
        var temp1 = (hh + upper + choose + k[round] + w[round]) >>> 0;
        var lower = rightRotate(a,2) ^ rightRotate(a,13) ^ rightRotate(a,22);
        var majority = (a & b) ^ (a & c) ^ (b & c);
        var temp2 = (lower + majority) >>> 0;
        hh=g; g=f; f=e; e=(d+temp1)>>>0; d=c; c=b; b=a; a=(temp1+temp2)>>>0;
      }
      h[0]=(h[0]+a)>>>0; h[1]=(h[1]+b)>>>0; h[2]=(h[2]+c)>>>0; h[3]=(h[3]+d)>>>0;
      h[4]=(h[4]+e)>>>0; h[5]=(h[5]+f)>>>0; h[6]=(h[6]+g)>>>0; h[7]=(h[7]+hh)>>>0;
    }

    return h.map(function (word) { return ("00000000" + word.toString(16)).slice(-8); }).join("");
  }

  function isCanonicalArrayIndex(key) {
    if (key === "0") return true;
    if (!/^[1-9][0-9]*$/.test(key)) return false;
    var number = Number(key);
    return number >= 0 && number < 4294967295 && String(number) === key;
  }

  function normalizer() {
    var visited = 0;
    var ancestors = [];

    function visit() {
      visited += 1;
      if (visited > NODE_BUDGET) throw {normalizerBudgetExceeded: true};
    }

    function normalizeValue(value, counted) {
      if (!counted) visit();
      if (value === null) return null;
      var kind = typeof value;
      if (kind === "undefined") return sentinel("undefined");
      if (kind === "bigint") return sentinel("bigint");
      if (kind === "symbol") return sentinel("symbol");
      if (kind === "function") return sentinel("function");
      if (kind === "boolean") return value;
      if (kind === "number") {
        if (value !== value) return sentinel("number-nan");
        if (value === Infinity) return sentinel("number-positive-infinity");
        if (value === -Infinity) return sentinel("number-negative-infinity");
        return Object.is(value, -0) ? 0 : value;
      }
      if (kind === "string") {
        var formed = toWellFormed(value);
        return {redactedString: true, utf8Bytes: utf8Bytes(formed)};
      }
      if (ancestors.indexOf(value) !== -1) return sentinel("cycle");

      var array;
      var proto;
      var names;
      var symbols;
      try {
        array = Array.isArray(value);
        proto = Object.getPrototypeOf(value);
        names = Object.getOwnPropertyNames(value);
        symbols = Object.getOwnPropertySymbols(value);
      } catch (_error) {
        throw {normalizerInspectionFailed: true};
      }
      if (symbols.length > 0) return sentinel("symbol-keyed-object");
      if (!array && proto !== Object.prototype && proto !== null) return sentinel("exotic-object");
      if (array && proto !== Array.prototype) return sentinel("exotic-object");

      ancestors.push(value);
      try {
        return array ? normalizeArray(value, names) : normalizeObject(value, names);
      } finally {
        ancestors.pop();
      }
    }

    function normalizeArray(value, names) {
      for (var n = 0; n < names.length; n += 1) {
        var key = names[n];
        if (key !== "length" && !isCanonicalArrayIndex(key)) return sentinel("exotic-object");
        if (isCanonicalArrayIndex(key) && Number(key) >= value.length) return sentinel("exotic-object");
      }
      var result = [];
      for (var i = 0; i < value.length; i += 1) {
        visit();
        var descriptor;
        try { descriptor = Object.getOwnPropertyDescriptor(value, String(i)); }
        catch (_error) { throw {normalizerInspectionFailed: true}; }
        if (!descriptor) {
          result.push(sentinel("sparse-hole"));
        } else if (!("value" in descriptor)) {
          result.push(sentinel("accessor"));
        } else {
          result.push(normalizeValue(descriptor.value, true));
        }
      }
      return result;
    }

    function normalizeObject(value, names) {
      names.sort();
      var result = {};
      var field = 0;
      for (var i = 0; i < names.length; i += 1) {
        var sourceKey = names[i];
        var descriptor;
        try { descriptor = Object.getOwnPropertyDescriptor(value, sourceKey); }
        catch (_error) { throw {normalizerInspectionFailed: true}; }
        if (!descriptor || !descriptor.enumerable) continue;
        visit();

        var formedKey = toWellFormed(sourceKey);
        var secret = isWellFormed(sourceKey) && secretNames[asciiFold(formedKey)] === true;
        var outputKey = preservedNames[sourceKey] === true && isWellFormed(sourceKey)
          ? sourceKey : "$field" + field++;
        if (secret) {
          result[outputKey] = "[REDACTED]";
        } else if (!("value" in descriptor)) {
          result[outputKey] = sentinel("accessor");
        } else {
          result[outputKey] = normalizeValue(descriptor.value, true);
        }
      }
      return result;
    }

    return function (value) { return normalizeValue(value, false); };
  }

  function truncation(kind, countName, count) {
    var detail = {kind: kind};
    detail[countName] = count;
    return {$truncation: detail};
  }

  function bound(value, depth) {
    if (value === null || typeof value !== "object") return value;
    if (depth === DEPTH_LIMIT) {
      return truncation("depth", "omittedCount", Array.isArray(value) ? value.length : Object.keys(value).length);
    }
    if (Array.isArray(value)) {
      var retained = value.slice(0, ARRAY_LIMIT).map(function (member) { return bound(member, depth + 1); });
      if (value.length > ARRAY_LIMIT) {
        retained.push(truncation("array-members", "omittedCount", value.length - ARRAY_LIMIT));
      }
      return retained;
    }
    var keys = Object.keys(value);
    var result = {};
    keys.slice(0, OBJECT_LIMIT).forEach(function (key) { result[key] = bound(value[key], depth + 1); });
    if (keys.length > OBJECT_LIMIT) {
      result.$truncation = {kind: "object-keys", omittedCount: keys.length - OBJECT_LIMIT};
    }
    return result;
  }

  function canonicalEnvelope(value) {
    var normalized;
    try {
      normalized = normalizer()(value);
    } catch (error) {
      normalized = error && error.normalizerBudgetExceeded
        ? sentinel("inspection-timeout") : sentinel("inspection-failure");
    }
    var encoded = JSON.stringify(bound(normalized, 0));
    var length = utf8Bytes(encoded);
    if (length <= BYTE_LIMIT) return encoded;
    return JSON.stringify({$truncation: {kind: "bytes", originalBytes: length, sha256: sha256(encoded)}});
  }

  var api = {
    normalize: canonicalEnvelope,
    sha256: sha256,
    toWellFormed: toWellFormed,
    utf8Bytes: utf8Bytes,
    inspectionFailure: function () { return JSON.stringify(sentinel("inspection-failure")); },
    inspectionTimeout: function () { return JSON.stringify(sentinel("inspection-timeout")); }
  };

  root.TightbeamFailureNormalizer = api;
  if (typeof module !== "undefined" && module.exports) module.exports = api;
}(typeof globalThis !== "undefined" ? globalThis : this));
