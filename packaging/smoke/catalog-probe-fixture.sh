#!/bin/sh
set -eu
root=${TB_PACKAGED_SMOKE_ROOT:?}
test -f "$root/packaged-smoke-only"
if test "${1-}" != catalog-probe; then
  exec "$root/tightbeam/bin/tightbeam" "$@"
fi
test "$#" = 5 && test "$2/$3" = anthropic/subscription
case "$4" in "$root"/base/*) ;; *) exit 64 ;; esac
case "$5" in
  'https://api.anthropic.com/v1/models?limit=100')
    printf '%s\n' '{"data":[{"id":"claude-sonnet-5","display_name":"Synthetic Sonnet","max_input_tokens":200000,"capabilities":{"effort":{"medium":{"supported":true}}}}]}' '200'
    printf '%s\n' 'synthetic discovery response' >> "$root/fixture-catalog.log"
    ;;
  *) exit 64 ;;
esac
