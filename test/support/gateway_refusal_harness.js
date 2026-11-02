"use strict";

const fs = require("node:fs");
const readline = require("node:readline");

const capturePath = process.argv[2];
process.on("exit", (code) => fs.writeFileSync(capturePath + ".exit", String(code)));
const options = () => ({
  configOptions: [
    {
      id: "model",
      name: "Model",
      type: "select",
      currentValue: "fixture-model",
      options: [{ value: "fixture-model", name: "Fixture Model" }]
    },
    {
      id: "effort",
      name: "Effort",
      type: "select",
      currentValue: "medium",
      options: [{ value: "medium", name: "Medium" }]
    }
  ]
});

const send = (frame, onWrite) => {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...frame }) + "\n", onWrite);
};

readline.createInterface({ input: process.stdin }).on("line", (line) => {
  if (!line.trim()) return;
  const request = JSON.parse(line);
  const params = request.params || {};

  switch (request.method) {
    case "initialize":
      return send({ id: request.id, result: { protocolVersion: 1 } });

    case "session/new":
      return send({
        id: request.id,
        result: { sessionId: "fixture-session", ...options() }
      });

    case "session/set_config_option":
      return send({ id: request.id, result: options() });

    case "session/set_mode":
      return send({ id: request.id, result: {} });

    case "session/prompt":
      fs.writeFileSync(capturePath, JSON.stringify({ method: request.method, params }));
      return send(
        {
          id: request.id,
          error: {
            code: -32000,
            message: "context_length_exceeded: prompt exceeds available context"
          }
        },
        () => process.exit(1)
      );

    case "session/close":
      return send({ id: request.id, result: {} });

    default:
      if (request.id !== undefined) {
        return send({
          id: request.id,
          error: { code: -32601, message: "unsupported fixture request" }
        });
      }
  }
});
