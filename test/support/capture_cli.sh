#!/bin/sh

stdout_path=$1
stderr_path=$2
shift 2

"$@" >"$stdout_path" 2>"$stderr_path"
status=$?
printf '%s' "$status"
