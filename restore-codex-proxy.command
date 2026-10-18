#!/bin/bash
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
exec /bin/bash "$script_dir/try-codex-proxy.command" --restore "$@"
