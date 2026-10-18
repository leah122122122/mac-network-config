#!/bin/bash
# Metadata only: never launch, quit, load app code, contact servers, or write files.
set +x
export LC_ALL=C
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
app=/Applications/ChatGPT.app
case "$#:$1" in
  0:) :;;
  1:--help|1:-h) echo '只读检测 /Applications/ChatGPT.app；可用 --app 指定实际应用。'; exit 0;;
  2:--app) app=$2;;
  *) echo '用法：/bin/bash inspect-chatgpt.command [--app /实际路径/ChatGPT.app]' >&2; exit 2;;
esac
[ "$(uname -s)" = Darwin ] || { echo '请在 Mac 本机运行；云端不能识别你的应用。' >&2; exit 1; }
case "$app" in *$'\n'*|*$'\r'*) echo '路径含换行，已停止。' >&2; exit 1;; esac
plist="$app/Contents/Info.plist"
[ -f "$plist" ] || { echo '指定位置没有可读取的应用 Info.plist；未执行任何应用。' >&2; exit 1; }
field() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || :; }
display() {
  local text=$2 pattern='^[A-Za-z0-9 ._+()/:-]{1,160}$'
  if [ -z "$text" ]; then text='未提供';
  elif ! [[ "$text" =~ $pattern ]]; then text='已读取，含特殊字符（不展开）'; fi
  printf '%s：%s\n' "$1" "$text"
}
echo 'ChatGPT 整合应用：最小只读身份检测'
echo '不预设 bundle ID、开发团队或技术框架；不读登录数据、配置、日志，不保存或上传结果。'
display 'Bundle ID' "$(field CFBundleIdentifier)"
display '应用名称' "$(field CFBundleName)"
display '显示名称' "$(field CFBundleDisplayName)"
display '版本' "$(field CFBundleShortVersionString)"
display '构建' "$(field CFBundleVersion)"
display '入口类（仅声明，不证明完整技术栈）' "$(field NSPrincipalClass)"
signature_ok=no; apple_ok=no
if codesign --verify --strict "$app" >/dev/null 2>&1; then
  signature_ok=yes
  echo '主应用签名/资源封印：校验通过（不等于已确认 OpenAI 身份或代理参数兼容）。'
else echo '主应用签名/资源封印：未通过或无法验证。'; fi
if codesign --verify --strict -R 'anchor apple generic' "$app" >/dev/null 2>&1; then
  apple_ok=yes
  echo 'Apple 签名信任要求：通过。'
else echo 'Apple 签名信任要求：未通过或无法验证。'; fi
codesign -d --verbose=4 "$app" 2>&1 | while IFS= read -r line; do
  case "$line" in
    Identifier=*) display '签名 Identifier' "${line#Identifier=}";;
    TeamIdentifier=*) display '签名 Team ID（实测值，不预设）' "${line#TeamIdentifier=}";;
    Signature=*) display '签名类型' "${line#Signature=}";;
  esac
done
echo '包内框架证据（只读名称/元数据，不加载框架代码）：'
electron=0; count=0
if [ -d "$app/Contents/Frameworks" ]; then
  while IFS= read -r -d '' framework; do
    count=$((count+1)); [ "$count" -le 20 ] || break
    name=$(basename "$framework")
    display '框架包' "$name"
    if [ "$name" = 'Electron Framework.framework' ]; then electron=1; fi
  done < <(find "$app/Contents/Frameworks" -maxdepth 2 -type d -name '*.framework' -prune -print0 2>/dev/null)
fi
[ "$count" -gt 0 ] || echo '未发现该目录中的内嵌 .framework；这不能单独证明是原生应用。'
if [ "$electron" -eq 1 ]; then
  echo '技术栈线索：存在 Electron 命名框架；不证明整个应用或 Codex 通道支持其代理参数。'
else echo '技术栈线索：没有发现上述 Electron 框架；不据此猜测 AppKit、SwiftUI 或其他实现。'; fi
# Use an already-installed, Apple-signed developer tool directly if available.
# Never invoke xcrun/otool installation shims or request a software installation.
developer_dir=$(xcode-select -p 2>/dev/null || :)
executable=$(field CFBundleExecutable)
case "$executable" in ''|.|..|*/*|*$'\n'*|*$'\r'*) executable='';; esac
tool_ready=no
app_real=$(CDPATH= cd -- "$app" && pwd -P)
binary_dir=$(CDPATH= cd -- "$app/Contents/MacOS" 2>/dev/null && pwd -P)
if [ "$signature_ok" = yes ] && [ "$apple_ok" = yes ] && [ "$binary_dir" = "$app_real/Contents/MacOS" ] && [ -n "$developer_dir" ] && [ -n "$executable" ] && [ -f "$app/Contents/MacOS/$executable" ] && [ ! -L "$app/Contents/MacOS/$executable" ]; then
  for tool in "$developer_dir/usr/bin/otool" "$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/otool"; do
    [ -x "$tool" ] && codesign --verify --strict -R 'anchor apple' "$tool" >/dev/null 2>&1 || continue
    echo '主程序静态链接证据（不执行主程序；不能覆盖动态加载或子进程）：'
    markers=$("$tool" -L "$app/Contents/MacOS/$executable" 2>/dev/null | awk '
      /\/AppKit.framework\// {print "链接：AppKit"}
      /\/SwiftUI.framework\// {print "链接：SwiftUI"}
      /\/Electron Framework.framework\// {print "链接：Electron Framework"}
      /\/Chromium Embedded Framework.framework\// {print "链接：Chromium Embedded Framework"}
    ' | sort -u)
    if [ -n "$markers" ]; then printf '%s\n' "$markers"; else echo '未提取上述框架的链接标记；不能由此确认完整技术栈。'; fi
    tool_ready=yes; break
  done
fi
[ "$tool_ready" = yes ] || echo '静态链接检查未运行：没有就绪的已验证 Apple 工具或有效主程序元数据；不安装软件，技术栈仍可能未确定。'
echo '结论：当前只确认以上本机元数据；代理启动兼容性尚未确认，不执行代理启动。'
echo '请仅把以上输出发回聊天。不要提供 Cookie、令牌、完整配置、应用日志或用户名路径。'
