"use strict";

var fs = require("fs");
var normalizer = require(process.argv[2]);
process.stdin.setEncoding("utf8");
process.stdin.once("data", function (input) {
  process.stdin.pause();
  var request;
  try {
    request = JSON.parse(input);
  } catch (_error) {
    process.stdout.write(normalizer.inspectionFailure(), function () { process.exit(0); });
    return;
  }

  var value;
  try {
    var run = new Function("\"use strict\";\n" + request.source);
    value = run();
  } catch (error) {
    value = error;
  }

  try {
    process.stdout.write(normalizer.normalize(value), function () { process.exit(0); });
  } catch (_error) {
    process.stdout.write(normalizer.inspectionFailure(), function () { process.exit(0); });
  }
});
