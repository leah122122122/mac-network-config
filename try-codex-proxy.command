#!/bin/bash
# One reversible desktop launch experiment, not a claimed OpenAI-supported fix.
# Apple Bash 3.2. Never source app/config/state files; never read authentication.
set +x
export LC_ALL=C
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
mode=test; requested_app=''
usage() {
  echo '用法：/bin/bash try-codex-proxy.command [--restore] [--app /实际路径/应用.app]'
  echo '只对本次正版 Electron 桌面应用启动指定 HTTP 代理 127.0.0.1:7897。'
  echo '不是已经确认兼容你版本的官方修复；不修改系统或应用配置。'
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0;;
    --restore) mode=restore; shift;;
    --app) [ "$#" -ge 2 ] || exit 2; requested_app=$2; shift 2;;
    *) usage >&2; exit 2;;
  esac
done
[ "$(uname -s)" = Darwin ] || { echo '请在你的 Mac 本机运行。没有执行启动或修改。' >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo '不要使用 sudo，请以普通用户运行。' >&2; exit 1; }
# Integrated ChatGPT is a separate compatibility target. Do not infer proxy
# support from its name, bundle ID, or an embedded Electron framework.
if [ "$mode" = test ]; then
  integrated_target=${requested_app:-/Applications/ChatGPT.app}
  integrated_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$integrated_target/Contents/Info.plist" 2>/dev/null || :)
  integrated_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$integrated_target/Contents/Info.plist" 2>/dev/null || :)
  if [ -d "$integrated_target" ] && { [ "$(basename "$integrated_target")" = ChatGPT.app ] || [ "$integrated_name" = ChatGPT ] || [ "$integrated_id" = com.openai.chat ]; }; then
    echo '整合版 ChatGPT 的代理启动已暂停：先核实真实身份与该版本的官方代理支持；不进入 TEST、不退出应用。'
    exec /bin/bash "$script_dir/inspect-chatgpt.command" --app "$integrated_target"
  fi
fi
[ -t 0 ] || { echo '需要交互式 Mac 终端确认，禁止无确认执行。' >&2; exit 1; }
for tool in codesign osascript nc stat shasum ps open nohup; do
  command -v "$tool" >/dev/null 2>&1 || { echo "缺少系统工具 $tool，已停止。" >&2; exit 1; }
done
[ -f "$script_dir/lib/mac-app-control.js" ] || { echo '请重新下载并解压整个仓库，保留 lib 文件夹。'; exit 1; }
state_root="$HOME/Library/Application Support/mac-network-config/desktop-proxy-test"
session="$state_root/active"
fail() { echo "$1" >&2; exit 1; }
private_path() {
  [ ! -L "$1" ] && [ "$(stat -f '%u' "$1" 2>/dev/null)" = "$(id -u)" ] &&
  { [ "$(stat -f '%Lp' "$1" 2>/dev/null)" = 700 ] || [ "$(stat -f '%Lp' "$1" 2>/dev/null)" = 600 ]; }
}
app_status() {
  app_pid=$(osascript -l JavaScript "$script_dir/lib/mac-app-control.js" status "$app" "${app_identifier:-com.openai.codex}" 2>/dev/null) || return 1
  case "$app_pid" in *[!0-9]*|0) return 1;; esac
  return 0
}
graceful_quit() {
  local i process_state expected_pid=$1 expected_start=$2
  app_status && [ "$app_pid" = "$expected_pid" ] && [ -n "$expected_start" ] &&
    [ "$(ps -p "$expected_pid" -o lstart= 2>/dev/null)" = "$expected_start" ] || return 1
  osascript -l JavaScript "$script_dir/lib/mac-app-control.js" quit "$app" "$expected_pid" "${app_identifier:-com.openai.codex}" >/dev/null 2>&1 || return 1
  for ((i=0;i<20;i++)); do
    app_status || return 1
    if [ -z "$app_pid" ]; then
      # AppKit may unregister the app before its process finishes shutting down.
      # Zombies have already exited; a reused PID must never be controlled.
      if ! process_state=$(ps -p "$expected_pid" -o stat= 2>/dev/null); then
        # A failed inspection alone is not proof that the process exited.
        kill -0 "$expected_pid" 2>/dev/null && return 1
        return 0
      fi
      case "$process_state" in '') return 1;; *Z*) return 0;; esac
      [ "$(ps -p "$expected_pid" -o lstart= 2>/dev/null)" = "$expected_start" ] || return 0
    elif [ "$app_pid" != "$expected_pid" ]; then
      return 1
    fi
    sleep 1
  done
  return 1
}
app_reject() {
  validation_stage=$1; validation_detail=$2
  return 1
}
show_rejection() {
  printf '未采用 %q：[%s] %s\n' "$app" "$validation_stage" "$validation_detail"
}
consider_electron_manifest() {
  local manifest=$1 framework_id framework_executable framework_root
  [ -f "$manifest" ] || return 1
  framework_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$manifest" 2>/dev/null || :)
  framework_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$manifest" 2>/dev/null || :)
  [ "$framework_id" = com.github.Electron.framework ] || [ "$framework_executable" = 'Electron Framework' ] || return 1
  framework_root=$(CDPATH= cd -- "$(dirname -- "$manifest")" && pwd -P) || return 1
  case "$framework_root" in "$app"/Contents/Frameworks/*) :;; *) engine_failure='框架元数据指向应用包之外。'; return 2;; esac
  while [ "$framework_root" != "$app/Contents/Frameworks" ]; do
    case "$framework_root" in *.framework) break;; esac
    framework_root=$(dirname -- "$framework_root")
  done
  case "$framework_root" in *.framework) :;; *) engine_failure='识别到 Electron 元数据，但不在有效 framework 包中。'; return 2;; esac
  # Verify the framework actually used for this test, rather than recursively
  # rejecting every independently packaged runtime elsewhere in the application.
  codesign --verify --strict "$framework_root" >/dev/null 2>&1 || { engine_failure='Electron 框架签名或资源完整性校验失败。'; return 2; }
  # Versions/A is not guaranteed; framework version metadata is informational.
  electron_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$manifest" 2>/dev/null || :)
  [ -n "$electron_version" ] || electron_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$manifest" 2>/dev/null || :)
  case "$electron_version" in ''|*[!0-9A-Za-z.+_-]*) electron_version='未提供（框架身份已识别）';; esac
  return 0
}
validate_app() {
  local plist executable_real signed_team requirement engine count=0
  validation_stage=''; validation_detail=''; app_identifier=''; electron_version=''; engine_failure=''
  case "$app" in *$'\n'*|*$'\r'*) app_reject 路径 '路径含换行，不自动处理。'; return 1;; esac
  [ -d "$app" ] || { app_reject 安装路径 '目录不存在或不可访问。'; return 1; }
  app=$(CDPATH= cd -- "$app" && pwd -P) || { app_reject 安装路径 '无法解析真实安装位置。'; return 1; }
  plist="$app/Contents/Info.plist"
  [ -f "$plist" ] && [ -d "$app/Contents/MacOS" ] || { app_reject 应用结构 '缺少 Contents/Info.plist 或 MacOS 目录。'; return 1; }
  app_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null) || { app_reject bundle-ID '无法读取 CFBundleIdentifier。'; return 1; }
  case "$app_identifier" in
    com.openai.codex|com.openai.chat) :;;
    *)
      case "$app_identifier" in ''|*[!0-9A-Za-z._-]*) app_identifier='未识别/格式异常';; esac
      app_reject bundle-ID "实际为 $app_identifier；不在允许的 Codex/ChatGPT 身份列表。"; return 1;;
  esac
  if [ "$mode" = test ]; then
    local product_name
    product_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist" 2>/dev/null || :)
    if [ "$app_identifier" = com.openai.chat ] || [ "$product_name" = ChatGPT ] || [ "$(basename "$app")" = ChatGPT.app ]; then
      app_reject 兼容性待确认 '这是 ChatGPT 应用；不能凭 bundle ID 或框架推断整合版 Codex 支持启动参数。请只运行 inspect-chatgpt.command。'
      return 1
    fi
  fi
  requirement="identifier \"$app_identifier\" and anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\""
  # Verify the signed main application and resource seal, matching the upstream
  # launcher. Recursive --deep rejects some independently packaged runtimes.
  # Neither bundle ID nor discovery metadata alone authorizes execution.
  if ! codesign --verify --strict -R "$requirement" "$app" >/dev/null 2>&1; then
    signed_team=$(codesign -d --verbose=4 "$app" 2>&1 | awk -F= '$1=="TeamIdentifier" && $2~/^[A-Z0-9]+$/ {print $2;exit}')
    if [ -n "$signed_team" ] && [ "$signed_team" != 2DC432GLL2 ]; then
      app_reject 签名团队 "实际团队 $signed_team，不是允许的 OpenAI 团队 2DC432GLL2。"
    else
      app_reject 签名完整性 '主应用签名、资源封印或 OpenAI 签名要求未通过；不启动。'
    fi
    return 1
  fi
  executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null) || { app_reject 可执行文件 '缺少 CFBundleExecutable。'; return 1; }
  case "$executable" in ''|.|..|*/*|*$'\n'*|*$'\r'*) app_reject 可执行文件 'CFBundleExecutable 格式不安全。'; return 1;; esac
  binary="$app/Contents/MacOS/$executable"
  [ -f "$binary" ] && [ -x "$binary" ] || { app_reject 可执行文件 '声明的程序不存在或不可执行。'; return 1; }
  executable_real=$(CDPATH= cd -- "$(dirname -- "$binary")" && pwd -P) || return 1
  case "$executable_real" in "$app"/Contents/MacOS) :;; *) app_reject 可执行文件 '可执行目录指向应用包之外。'; return 1;; esac
  [ ! -L "$binary" ] || { app_reject 可执行文件 '主程序是符号链接，不自动执行。'; return 1; }
  app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || :)
  [ -n "$app_version" ] || app_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist" 2>/dev/null || :)
  case "$app_version" in ''|*[!0-9A-Za-z.+_-]*) app_version='未提供';; esac
  binary_hash=$(shasum -a 256 "$binary" 2>/dev/null) || { app_reject 完整性记录 '无法计算程序校验值。'; return 1; }
  binary_hash=${binary_hash%% *}
  for engine in "$app/Contents/Frameworks/Electron Framework.framework/Resources/Info.plist" "$app/Contents/Frameworks/Electron Framework.framework/Versions/A/Resources/Info.plist"; do
    consider_electron_manifest "$engine" && return 0
    [ -z "$engine_failure" ] || { app_reject 框架完整性 "$engine_failure"; return 1; }
  done
  if [ -d "$app/Contents/Frameworks" ]; then
    while IFS= read -r -d '' engine; do
      count=$((count+1)); [ "$count" -le 256 ] || break
      consider_electron_manifest "$engine" && return 0
      [ -z "$engine_failure" ] || { app_reject 框架完整性 "$engine_failure"; return 1; }
    done < <(find "$app/Contents/Frameworks" -maxdepth 6 -type f -name Info.plist -print0 2>/dev/null)
  fi
  app_reject 框架 "OpenAI 签名已通过，bundle=$app_identifier，版本=$app_version；未找到可识别的 Electron 框架，可能是原生应用或不同打包方式，不能安全套用 Electron 参数。"
  return 1
}
discover_apps() {
  local path root registered
  discovered=()
  # Running apps and LaunchServices can find renamed/relocated bundles.
  if registered=$(osascript -l JavaScript "$script_dir/lib/mac-app-control.js" discover 2>/dev/null); then
    while IFS= read -r path; do [ -z "$path" ] || discovered+=("$path"); done <<< "$registered"
  else
    echo '提示：运行应用/LaunchServices 查询未成功，继续使用 Spotlight 和目录候选；不跳过真实性检查。'
  fi
  if command -v mdfind >/dev/null 2>&1; then
    while IFS= read -r -d '' path; do
      discovered+=("$path")
    done < <(mdfind -0 'kMDItemContentType == "com.apple.application-bundle" && (kMDItemCFBundleIdentifier == "com.openai.codex" || kMDItemCFBundleIdentifier == "com.openai.chat" || kMDItemFSName == "*Codex*.app"cd || kMDItemFSName == "ChatGPT.app"cd)' 2>/dev/null)
  fi
  # Non-indexed standard installations, including renamed/nested .app folders.
  for root in /Applications "$HOME/Applications"; do
    [ -d "$root" ] || continue
    while IFS= read -r -d '' path; do discovered+=("$path"); done < <(find "$root" -maxdepth 4 -type d -iname '*.app' -prune \( -iname '*codex*.app' -o -iname '*chatgpt*.app' \) -print0 2>/dev/null)
  done
  # Fixed paths are fallback candidates, not the discovery boundary.
  discovered+=(/Applications/ChatGPT.app /Applications/Codex.app "$HOME/Applications/ChatGPT.app" "$HOME/Applications/Codex.app")
}

archive_session() {
  local destination
  destination=$(mktemp -d "$state_root/finished-XXXXXX") || return 1
  mv "$session" "$destination/session" || return 1
}
if [ "$mode" = restore ]; then
  [ -d "$session" ] || { echo '没有待恢复的本次启动记录；没有任何持久代理配置需要撤销。'; exit 0; }
  private_path "$state_root" && private_path "$session" || fail '状态目录权限或所有者异常；未操作应用。'
  for file in app-path binary-hash original-pid; do
    [ -f "$session/$file" ] && private_path "$session/$file" || fail '启动记录不完整或权限异常；未操作应用。'
  done
  app=$(cat "$session/app-path")
  case "$app" in /*.app) :;; *) fail '启动记录中的应用路径不合法。';; esac
  validate_app || { show_rejection; fail '未操作应用。请正常退出测试应用后从 Finder 打开。'; }
  if [ -f "$session/bundle-id" ]; then
    private_path "$session/bundle-id" && [ "$(cat "$session/bundle-id")" = "$app_identifier" ] || fail '恢复记录与当前 bundle ID 不符，未操作应用。'
  else
    [ "$app_identifier" = com.openai.codex ] || fail '旧恢复记录只允许原 com.openai.codex 身份。'
  fi
  [ "$(cat "$session/binary-hash")" = "$binary_hash" ] || fail '应用已更新，不控制旧 PID。请正常退出应用后从 Finder 打开即可撤销本次启动参数。'
  original_pid=$(cat "$session/original-pid")
  if [ "$original_pid" = not-running ]; then
    original_was_running=no
  else
    case "$original_pid" in ''|*[!0-9]*|0) fail '原运行状态记录异常；未操作应用。';; esac
    original_was_running=yes
  fi
  app_status || fail '无法安全确认应用实例；未退出任何进程。'
  saved_pid=''; saved_start=''
  if [ -f "$session/test-pid" ] && [ -f "$session/pid-start" ]; then
    private_path "$session/test-pid" && private_path "$session/pid-start" || fail '进程记录权限异常。'
    saved_pid=$(cat "$session/test-pid"); saved_start=$(cat "$session/pid-start")
  fi
  case "$saved_pid" in *[!0-9]*|0) fail '进程记录异常；未退出任何进程。';; esac
  if [ -n "$app_pid" ] && [ "$app_pid" = "$saved_pid" ] && [ -z "$saved_start" ]; then
    fail '进程启动时间记录不完整，无法安全自动退出。请正常退出测试应用后从 Finder 打开；未关闭其他实例。'
  fi
  echo '恢复：只撤销本次启动参数，不修改代理/DNS/Clash/Codex 配置，也不回滚聊天与工作区数据。'
  if [ -n "$app_pid" ] && [ "$app_pid" = "$saved_pid" ] && [ -n "$saved_start" ] && [ "$(ps -p "$app_pid" -o lstart= 2>/dev/null)" = "$saved_start" ]; then
    printf '请先保存工作；输入 RESTORE 确认正常退出测试应用并按原运行状态恢复：'
    read -r answer
    [ "$answer" = RESTORE ] || { echo '已取消，没有更改。'; exit 0; }
    graceful_quit "$saved_pid" "$saved_start" || fail '应用实例已变化或未完成正常退出，未强制结束。请处理保存提示后重试。'
    # open is invoked from the original shell, never the modified child environment.
    if [ "$original_was_running" = yes ]; then
      open -a "$app" >/dev/null 2>&1 || fail '应用已退出，但普通启动失败；请从 Finder 打开。记录保留。'
    else echo '启动对照前应用未运行；现已正常退出，保持关闭。'; fi
  elif [ -n "$app_pid" ]; then
    echo '原测试实例已结束或身份已变化。保留当前实例，未退出它，也未再次启动。'
  elif [ "$original_was_running" = yes ]; then
    printf '测试实例已退出；输入 RESTORE 确认按原方式打开应用：'
    read -r answer
    [ "$answer" = RESTORE ] || { echo '已取消。'; exit 0; }
    open -a "$app" >/dev/null 2>&1 || fail '普通启动失败；请从 Finder 打开。记录保留。'
  else
    echo '启动对照前应用未运行，测试实例也已退出；保持关闭。'
  fi
  archive_session || fail '应用恢复步骤已完成，但记录归档失败。'
  echo '本次显式代理启动已结束。后续从 Finder/Dock 启动不带本工具参数。'
  exit 0
fi

[ ! -e "$session" ] || fail '已有启动记录。请运行 restore-codex-proxy.command，避免重复启动。'
if [ -n "$requested_app" ]; then
  app=$requested_app
  validate_app || { show_rejection; fail '指定应用不满足安全启动条件；未执行程序。'; }
else
  echo '自动发现：当前运行应用、LaunchServices、Spotlight 及标准应用目录；候选仍须逐项验证。'
  echo '路径可能含用户名；如需分享失败原因，请先脱敏。'
  discover_apps
  candidates=(); checked=(); running_candidates=(); missing_paths=()
  for candidate in "${discovered[@]}"; do
    app=$candidate
    if [ -d "$app" ]; then
      normalized=$(CDPATH= cd -- "$app" && pwd -P) && app=$normalized
    fi
    duplicate=no
    for seen_path in "${checked[@]}"; do [ "$seen_path" != "$app" ] || duplicate=yes; done
    [ "$duplicate" = no ] || continue
    checked+=("$app")
    if validate_app; then
      printf '通过：%q；bundle=%s；版本=%s；Electron=%s\n' "$app" "$app_identifier" "$app_version" "$electron_version"
      candidates+=("$app")
      if app_status && [ -n "$app_pid" ]; then running_candidates+=("$app"); fi
    elif [ "$validation_stage" = 安装路径 ]; then
      missing_paths+=("$app")
    else
      show_rejection
    fi
  done
  if [ "${#candidates[@]}" -eq 0 ]; then
    for missing_path in "${missing_paths[@]}"; do printf '[安装路径] %q 不存在或不可访问。\n' "$missing_path"; done
    fail '未找到可安全进行 Electron 代理测试的应用；发现应用不等于签名或框架已通过。未退出或启动任何应用。'
  elif [ "${#running_candidates[@]}" -eq 1 ]; then
    app=${running_candidates[0]}
    echo '优先使用当前运行且已通过真实性/框架校验的应用。'
  elif [ "${#candidates[@]}" -eq 1 ]; then
    app=${candidates[0]}
  else
    echo '发现多份已验证应用，请选择你实际使用的一份（此时不会启动）：'
    for ((index=0;index<${#candidates[@]};index++)); do printf '%s) %q\n' "$((index+1))" "${candidates[$index]}"; done
    printf '输入编号，其他输入取消：'; read -r choice
    case "$choice" in ''|*[!0-9]*) fail '已取消。';; esac
    [ "${#choice}" -le 4 ] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#candidates[@]}" ] || fail '编号不在范围内，已取消。'
    app=${candidates[$((10#$choice-1))]}
  fi
  validate_app || { show_rejection; fail '所选应用发生变化，未执行程序。'; }
fi
app_status || fail '无法安全识别当前桌面实例，或另一份安装正在运行；已停止。'
original_pid=$app_pid
original_start=''
if [ -n "$original_pid" ]; then
  original_start=$(ps -p "$original_pid" -o lstart= 2>/dev/null)
  [ -n "$original_start" ] || fail '无法确认原进程启动时间，已停止。'
fi
nc -z -G 2 -w 2 127.0.0.1 7897 >/dev/null 2>&1 || fail '本机 7897 未监听，不能进行这一次显式代理启动测试。未更改设置。'
echo "已识别桌面应用：$app_identifier；应用版本=$app_version；Electron=$electron_version。"
echo '版本/框架检查只确认测试对象，不能证明该应用所有组件会采用这些参数；本次启动是唯一兼容性对照。'
echo '将执行：'
echo '  1. 保存本地版本/原运行状态记录；不复制含凭据的配置或登录文件（配置不会修改）。'
echo '  2. 请求正常退出这份桌面应用，再启动同一个已验证可执行文件。'
echo '  3. 只在新进程设置 HTTP_PROXY/HTTPS_PROXY 及小写形式=http://127.0.0.1:7897。'
echo '  4. 新进程清除 ALL_PROXY/WS_PROXY/WSS_PROXY；NO_PROXY 仅保留本机回环。'
echo '  5. Electron 参数 --proxy-server=http://127.0.0.1:7897；本机回环绕过代理。'
echo '不改系统、launchd、Clash、provider、WebSocket 传输或 app 文件；TLS 校验保留。'
echo '仅在这次应用子进程清除 NODE_OPTIONS、TLS 禁用和 Electron 调试/Node 模式变量，避免改变启动方式或关闭校验。'
echo '风险：桌面当前任务会被中断；本次桌面及继承该环境的子进程使用 7897。浏览器进程和系统网络设置不变。'
echo '中断或失败时仍可运行 restore-codex-proxy.command；也可正常退出测试应用后从 Finder 打开。'
echo '自动恢复会保留原来的运行状态：原来运行则普通重开，原来未运行则保持关闭；不会结束后来另开的实例。'
printf '请保存工作；输入 TEST 同意这一次启动对照，其他输入取消：'
read -r answer
[ "$answer" = TEST ] || { echo '已取消，没有启动应用或修改设置。'; exit 0; }

[ ! -L "$state_root" ] || fail '状态目录是符号链接，已停止。'
mkdir -p "$state_root" || fail '无法创建本地启动记录。'
private_path "$state_root" || fail '状态目录不是当前用户私有目录，已停止。'
mkdir "$session" || fail '已有并行启动记录，已停止。'
{
  printf '%s\n' "$app" > "$session/app-path" &&
  printf '%s\n' "$binary_hash" > "$session/binary-hash" &&
  printf '%s\n' "$app_identifier" > "$session/bundle-id" &&
  printf '%s\n' "$app_version" > "$session/app-version" &&
  printf '%s\n' "$electron_version" > "$session/electron-version" &&
  printf '%s\n' "${original_pid:-not-running}" > "$session/original-pid" &&
  printf '%s\n' 'process-only; no configuration edited; not a credential/config backup' > "$session/scope"
} || fail '无法保存启动前状态，未退出或启动应用。'
trap 'echo "操作中断；启动记录保留，请使用恢复入口。"; exit 130' INT TERM
# Recheck after confirmation to avoid acting on an installation swapped meanwhile.
previous_hash=$binary_hash
validate_app && [ "$binary_hash" = "$previous_hash" ] || fail '确认期间应用发生变化；未退出应用，记录保留。'
app_status || fail '确认期间应用实例发生变化；未退出应用，记录保留。'
if [ -n "$app_pid" ]; then
  [ "$app_pid" = "$original_pid" ] || fail '确认期间出现不同实例；未操作它，记录保留。'
  graceful_quit "$original_pid" "$original_start" || fail '应用实例已变化或未完成正常退出，未强制结束；记录保留，可再次恢复。'
fi
# Do not log app stdout/stderr, which could contain personal/authentication data.
# Parent environment and launchd remain unchanged. Do not install a LaunchAgent.
nohup /usr/bin/env -u ALL_PROXY -u all_proxy -u WS_PROXY -u WSS_PROXY -u ws_proxy -u wss_proxy \
  -u NODE_TLS_REJECT_UNAUTHORIZED -u NODE_OPTIONS -u ELECTRON_RUN_AS_NODE -u ELECTRON_ENABLE_LOGGING -u ELECTRON_LOG_FILE \
  HTTP_PROXY=http://127.0.0.1:7897 HTTPS_PROXY=http://127.0.0.1:7897 \
  http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897 \
  NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1 \
  "$binary" --proxy-server=http://127.0.0.1:7897 '--proxy-bypass-list=localhost;127.0.0.1;[::1]' \
  </dev/null >/dev/null 2>&1 &
test_pid=$!
printf '%s\n' "$test_pid" > "$session/test-pid"
ps -p "$test_pid" -o lstart= > "$session/pid-start" 2>/dev/null
[ -s "$session/pid-start" ] || fail '启动进程未保持运行，未能确认测试启动。记录保留，可用恢复入口。'
for ((attempt=0;attempt<20;attempt++)); do
  app_status || fail '无法确认新实例，未对任何进程作进一步操作；记录保留。'
  if [ "$app_pid" = "$test_pid" ]; then break; fi
  [ -z "$app_pid" ] || fail '新启动移交给其他实例，测试未成立，未关闭该实例；记录保留。'
  kill -0 "$test_pid" 2>/dev/null || fail '新启动已结束，测试未成立；记录保留。'
  sleep 1
done
[ "$app_pid" = "$test_pid" ] || fail '20 秒内未确认桌面实例；不宣称代理已生效。记录保留。'
echo '已确认新桌面实例来自本次带参数启动；这仍不证明所有组件实际走代理或问题已修复。'
echo '现在只做一次验证：新建桌面对话，发送“只回复 OK”，再连续发送两条短消息；观察 10 分钟能否正常回复。'
echo '同时刷新 ChatGPT 网页并发送一条消息，确认原使用方式仍正常。'
printf '结果：输入 OK 表示两边均正常，FAIL 表示仍重连，其他输入记为尚未验证：'
read -r outcome
case "$outcome" in OK) outcome='用户报告本次桌面与网页验证通过；长期稳定性待观察';; FAIL) outcome='用户报告本次仍失败；不重复启动或改配置';; *) outcome='尚未取得用户应用验证结果';; esac
printf '%s\n' "$outcome" > "$session/outcome"
echo "$outcome"
echo '请只回复：应用版本、Electron 版本和上述结果；不要发原始应用日志或启动记录路径。'
echo '恢复：运行同目录 restore-codex-proxy.command，或正常退出测试应用后从 Finder/Dock 打开。'
