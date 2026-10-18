#!/bin/bash
# Local launcher. No downloads, installs or configuration writes.
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
/bin/bash "$script_dir/diagnose-macos.sh" "$@"
result=$?
if [ -t 0 ]; then
  printf '\n运行结束（退出码 %s）。按回车关闭。' "$result"
  read -r unused
fi
exit "$result"
