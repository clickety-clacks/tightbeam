# Pi opencode-go pre-code live proof — 2026-08-23

This report records the live seam checks that preceded product changes for
`asg_40166440-fa20-4763-8c2f-340b15a1bb75`. The host ran Pi 0.84.1. The
credential stayed in its existing 0600 OpenCode store and was read in-process.
No credential bytes appeared in an argument, standard output, standard error,
the Tightbeam database, or this report.

| Probe | Exact model | Result |
|---|---|---|
| Pi provider client, OpenAI Responses API, `maxTokens: 1` (Pi floors the request to the provider minimum of 16) | `opencode-go/gpt-5.6-luna` | HTTP 200; Pi result `stop_reason=stop`; 5 output tokens; no error |
| Direct provider control using the same in-memory credential and Pi request headers | `opencode-go/deepseek-v4-flash` | HTTP 403; provider `RegionError` |

The successful request used `https://opencode.ai/zen/go/v1/responses`. It sent
the model as `gpt-5.6-luna`, a short `Reply with OK.` input, and
`max_output_tokens: 16`. The client supplied the bearer credential only as an
HTTP header. The process never placed it in `argv`.

The control proves that catalog membership alone does not prove model
liveness. The accepted model for the later product smoke is
`opencode-go/gpt-5.6-luna`.

The public Pi catalog endpoint also returned HTTP 200 for
`https://pi.dev/api/models/providers/opencode-go`. It returned 21 provider-
stamped models, including each model's API, context window, output limit, and
thinking-level map. This observation identifies the catalog source. It is not
the post-change Tightbeam catalog proof.
