#!/bin/bash
# macOS /bin/bash 3.2 compatible. No configuration writes, credentials or uploads.
# Avoid nounset: empty arrays must also work with Apple's Bash 3.2.
export LC_ALL=C
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
umask 077

usage() {
  cat <<'EOF'
用法：/bin/bash diagnose-macos.sh [--http-port 数字] [--socks-port 数字]
只读诊断，报告保存到本机 ~/Library/Logs/mac-network-config/。
可选端口只能指向本机 127.0.0.1；不支持代理密码或远程代理。
--help 显示说明，不执行诊断。按 Control+C 可停止。
EOF
}
http_override=''; socks_override=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --http-port|--socks-port)
      option=$1
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      case "$2" in ''|*[!0-9]*) echo '端口必须是 1–65535 的整数。' >&2; exit 2;; esac
      [ "${#2}" -le 5 ] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ] || exit 2
      if [ "$option" = --http-port ]; then http_override=$2; else socks_override=$2; fi
      shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
if [ "$(uname -s)" != Darwin ]; then
  echo '仅支持在你的 Mac 本机运行。已停止：不会生成网络诊断结论。' >&2
  exit 1
fi
for tool in curl scutil sw_vers nc awk mktemp tee dscacheutil; do
  command -v "$tool" >/dev/null 2>&1 || { echo "缺少系统工具：$tool；已停止。" >&2; exit 1; }
done
[ "$(id -u)" -ne 0 ] || { echo '请以普通用户运行，不要使用 sudo。' >&2; exit 1; }

report_root="$HOME/Library/Logs/mac-network-config"
mkdir -p "$report_root" || exit 1
report_dir=$(mktemp -d "$report_root/run-$(date +%Y%m%d-%H%M%S)-XXXXXX") || exit 1
report="$report_dir/报告.txt"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mac-network-diag.XXXXXX") || exit 1
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT
trap 'echo "诊断已中止，现有报告不完整。"; exit 130' INT TERM
exec > >(tee "$report") 2>&1

# Some native resolver commands have no timeout flag. Kill only this child.
bounded() {
  local limit=$1 child guard result
  shift
  "$@" > "$scratch/bounded.out" 2>/dev/null & child=$!
  ( sleep "$limit"; kill -TERM "$child" 2>/dev/null ) & guard=$!
  wait "$child" 2>/dev/null; result=$?
  kill "$guard" 2>/dev/null || :
  wait "$guard" 2>/dev/null || :
  cat "$scratch/bounded.out"
  return "$result"
}
value() { awk -v key="$1" '$1 == key && $2 == ":" {print $3; exit}' "$scratch/proxy"; }
is_loopback() { case "$1" in 127.0.0.1|localhost|::1) return 0;; *) return 1;; esac; }
valid_port() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

echo 'macOS 网络只读诊断 v1'
echo "执行地点：当前运行脚本的 Mac；时间：$(date '+%Y-%m-%d %H:%M:%S %z')"
echo '不修改配置，不读取订阅、密码、钥匙串、Cookie、登录文件或应用日志，不上传报告。'
echo '将向固定的 OpenAI / ChatGPT / GitHub 域名发送无登录 HTTPS 请求；服务商会看到出口 IP。'
echo '预计 3–10 分钟，超时较多时更久。按 Control+C 可停止。'
echo '分享前请检查 DNS 服务器地址、系统版本、时间等信息；不要公开上传整份报告。'
echo
echo '一、系统与 Codex 应用元数据'
os_version=$(sw_vers -productVersion)
arch=$(uname -m)
echo "macOS：$os_version；当前进程架构：$arch；内核：$(uname -r)"
arm_capable=$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)
translated=$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)
echo "Apple Silicon 能力标记：$arm_capable；Rosetta 转译标记：$translated"
echo '架构标记只能辅助排查兼容性；未据此判断 Codex 支持哪些系统。'
app_found=0; compat_problem=0
for app in /Applications/Codex.app "$HOME/Applications/Codex.app"; do
  plist="$app/Contents/Info.plist"
  [ -f "$plist" ] || continue
  app_found=1
  for key in CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion; do
    v=$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || :)
    # Only version strings; never print paths or arbitrary plist values.
    case "$v" in ''|*[!0-9A-Za-z.+_-]*) v='未提供或格式未识别';; esac
    echo "Codex $key：$v"
    if [ "$key" = LSMinimumSystemVersion ]; then
      case "$v" in
        ''|*[!0-9.]*) : ;;
        *)
          if awk -v current="$os_version" -v minimum="$v" 'BEGIN {split(current,a,"."); split(minimum,b,"."); for(i=1;i<=3;i++) {if(a[i]+0<b[i]+0) exit 0; if(a[i]+0>b[i]+0) exit 1} exit 1}'; then
            compat_problem=1
            echo '兼容性观测：系统版本低于此应用声明的最低版本。'
          fi ;;
      esac
    fi
  done
done
[ "$app_found" -eq 1 ] || echo '常见安装目录未找到 Codex.app；不代表未安装，也未检查应用数据。'
echo
echo '二、当前生效的系统代理（scutil；不输出远程地址或 PAC URL）'
scutil --proxy > "$scratch/proxy" 2>/dev/null
for kind in HTTP HTTPS SOCKS; do
  enabled=$(value "${kind}Enable"); host=$(value "${kind}Proxy"); port=$(value "${kind}Port")
  if is_loopback "$host"; then display='本机回环地址'; elif [ -n "$host" ]; then display='非回环地址（已隐藏）'; else display='未提供'; fi
  valid_port "$port" || port='未提供'
  echo "$kind：启用=${enabled:-0/未提供}；服务器=$display；端口=$port"
done
echo "PAC 自动配置：$(value ProxyAutoConfigEnable)；自动发现：$(value ProxyAutoDiscoveryEnable)（空值表示未提供）"
echo 'PAC 脚本、例外列表和远程代理不会被读取或执行；这里只检测本机代理。'
for name in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY; do
  if /usr/bin/printenv "$name" >/dev/null 2>&1; then echo "环境变量 $name 已设置（值隐藏；测试忽略它）"; fi
done
echo '注意：curl 不自动遵循 macOS 系统代理/PAC；下面显式指定每条测试路径。'
echo
echo '三、DNS 配置与系统解析'
scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/ {print "DNS 服务器（本地记录，分享前检查）：" $3} /flags[ ]*:/ {print "解析器 " $0}' | head -60
targets=(chatgpt.com auth.openai.com auth0.openai.com api.openai.com github.com api.github.com)
dns_failed=0
for host in "${targets[@]}"; do
  bounded 6 dscacheutil -q host -a name "$host" > "$scratch/dns"
  dns_rc=$?
  count=$(awk '/^[[:space:]]*(ip_address|ipv6_address):/ {n++} END {print n+0}' "$scratch/dns")
  fake=$(awk '/ip_address:[[:space:]]+198\.(18|19)\./ {n++} END {print n+0}' "$scratch/dns")
  if [ "$count" -gt 0 ]; then
    echo "$host：系统解析返回 $count 个地址（隐藏具体地址）；Fake-IP 范围条目=$fake"
  else
    echo "$host：未得到系统解析地址（退出码 $dns_rc；可能失败、超时或工具未返回）"
    dns_failed=$((dns_failed+1))
  fi
done
echo '198.18/15 可能是 Clash Fake-IP 的正常表现，不能单独认定 DNS 污染。'
echo '系统 DNS 与 SOCKS5h 的代理端解析可以不同；本工具不绕开你的配置查询外部 DNS。'
echo
echo '四、本机常见代理端口（TCP 探测，不读取进程或 Clash 配置）'
ports=(7890 7891 7897 1080 10808 10809)
for kind in HTTP HTTPS SOCKS; do
  host=$(value "${kind}Proxy"); port=$(value "${kind}Port")
  if is_loopback "$host" && valid_port "$port"; then ports+=("$port"); fi
done
[ -z "$http_override" ] || ports+=("$http_override")
[ -z "$socks_override" ] || ports+=("$socks_override")
open_ports=(); seen=' '
for port in "${ports[@]}"; do
  case "$seen" in *" $port "*) continue;; esac
  seen="$seen$port "
  if nc -z -G 1 -w 1 127.0.0.1 "$port" >/dev/null 2>&1; then
    echo "127.0.0.1:$port：TCP 可连接（尚未证明是 Clash 或代理）"
    open_ports+=("$port")
  else
    echo "127.0.0.1:$port：TCP 不可连接"
  fi
done
echo '只探测 IPv4 回环；若仅监听 ::1、自定义地址或需认证，请手动核对 Clash 页面。'

# curl -q disables ~/.curlrc. env removes inherited proxy credentials/routing.
# No redirects, body/header recording, cookies, auth, -k, or verbose errors.
request() {
  local route=$1 url=$2 limit=$3
  local args=()
  if [ "$route" = direct ]; then args=(--proxy '' --noproxy '*'); else args=(--proxy "$route" --noproxy ''); fi
  metrics=$(/usr/bin/env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u no_proxy -u NO_PROXY \
    /usr/bin/curl -q --silent --output /dev/null --connect-timeout 5 --max-time "$limit" \
    --proto '=https' "${args[@]}" \
    --write-out '%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{ssl_verify_result}' \
    "$url" 2>/dev/null)
  curl_rc=$?
  [ -n "$metrics" ] || metrics='000 0 0 0 0 0 -1'
  read -r code dns tcp tls first total verify <<< "$metrics"
}
routes=(direct); labels=('不使用显式代理')
http_selected=''; socks_selected=''
echo
echo '五、代理协议验证（GitHub HTTPS；成功仅表示这一时刻该目标可达）'
for protocol in http socks5h; do
  if [ "$protocol" = http ]; then override=$http_override; else override=$socks_override; fi
  if [ -n "$override" ]; then candidates=("$override"); else candidates=("${open_ports[@]}"); fi
  for port in "${candidates[@]}"; do
    request "$protocol://127.0.0.1:$port" https://github.com/ 6
    echo "$protocol 端口 $port：curl=$curl_rc，HTTP=$code"
    if [ "$curl_rc" -eq 0 ] && [ "$code" != 000 ]; then
      routes+=("$protocol://127.0.0.1:$port"); labels+=("$protocol 本机端口 $port")
      if [ "$protocol" = http ]; then http_selected=$port; else socks_selected=$port; fi
      break
    fi
  done
  # Explicit user port is still compared even if GitHub discovery fails.
  if [ -n "$override" ]; then
    if { [ "$protocol" = http ] && [ -z "$http_selected" ]; } || { [ "$protocol" = socks5h ] && [ -z "$socks_selected" ]; }; then
      routes+=("$protocol://127.0.0.1:$override"); labels+=("$protocol 指定端口 $override（协议尚未验证）")
    fi
  fi
done
echo '自动选每种协议首个可访问 GitHub 的端口；其他端口未做完整比较。可用参数指定 Clash 实际端口重测。'
echo
echo '六、固定 HTTPS 端点，两轮独立请求（不使用账号）'
echo '不使用显式代理 ≠ 物理直连：Clash TUN、其他 VPN、透明路由可能仍接管。'
echo '累计耗时单位为秒：DNS / TCP / TLS / 首字节 / 总计。代理路径 DNS/TCP 常只反映本机代理，不能与直连逐项等同。'
echo 'HTTP 401/403/404/429 可证明收到 HTTP 响应，但不能证明登录、地区权限或 Codex 功能正常。'
echo '端点说明：ChatGPT 网页、当前/兼容登录域名、OpenAI API、GitHub 网页/API；不是完整 Codex 会话。'
urls=(https://chatgpt.com/ https://auth.openai.com/ https://auth0.openai.com/ https://api.openai.com/v1/models https://github.com/ https://api.github.com/)
targets+=(chatgpt.com)
urls+=(https://chatgpt.com/backend-api/codex)
echo '另测 Codex 候选服务路径 /backend-api/codex（可能返回 401/403/404；不是已认证 API 功能测试）。'
: > "$scratch/results"
for ((r=0; r<${#routes[@]}; r++)); do
  echo
  echo "路径：${labels[$r]}"
  for ((h=0; h<${#targets[@]}; h++)); do
    for round in 1 2; do
      request "${routes[$r]}" "${urls[$h]}" 12
      echo "${urls[$h]} 第$round轮：curl=$curl_rc HTTP=$code；DNS=$dns TCP=$tcp TLS=$tls 首字节=$first 总计=$total；证书校验=$verify"
      echo "$r $h $round $curl_rc $code $total" >> "$scratch/results"
    done
  done
done
echo
echo '七、结论（仅针对这次本机样本）'
echo '【已经确认的观测】'
[ "$compat_problem" -eq 0 ] || echo '软件兼容性：当前 macOS 低于已找到 Codex.app 声明的最低系统版本，需要核对安装包与官方支持要求。'
echo "系统 DNS 未返回地址的域名数：$dns_failed / 6。这不等同于已经确认 DNS 故障原因。"
for ((r=0; r<${#routes[@]}; r++)); do
  summary=$(awk -v r="$r" '$1==r {n++; if($4==0 && $5!="000") ok++; else fail++; if($4==28) timeout++; if($4==35 || $4==60) tls++; if($4==5 || $4==6) dns++} END {printf "HTTP响应 %d/%d；传输失败 %d；超时 %d；TLS类错误 %d；解析类错误 %d",ok,n,fail,timeout,tls,dns}' "$scratch/results")
  echo "${labels[$r]}：$summary"
done
[ "${#routes[@]}" -gt 1 ] || echo '未自动验证可用的本机代理路径；不能据此判定节点无效（也可能端口不同或 GitHub 被单独阻断）。'
echo '【可能存在的问题】'
awk '
  $2==0 && $4==0 && $5!="000" {ok[$1]++}
  $2==0 && $4!=0 {bad[$1]++}
  {key=$1 ":" $2; if($4==0 && $5!="000") pass[key]++; else fail[key]++}
  $4==5 || $4==6 {dns=1}
  $4==7 {tcp=1}
  $4==28 {timeout=1}
  $4==35 || $4==60 {tls=1}
  $5==401 || $5==403 || $5==429 {http=1}
  END {
    for(k in pass) if(fail[k]>0) {print "- 同一路径同一端点两轮有成功也有失败：本次观察到间歇性传输异常，需要扩大时段验证。"; break}
    if (bad[0]>0) for(r in ok) if(r!=0 && ok[r]>0) {print "- ChatGPT 显式代理收到响应、无显式代理有传输失败：应用未走代理或路由差异值得排查；尚未证明 Codex 根因。"; break}
    if (dns) print "- 存在解析类错误：检查系统/代理 DNS；SOCKS5h 失败也可能来自代理端解析或代理协议。"
    if (tcp) print "- 存在 TCP 连接失败：检查网络、监听端口和防火墙；不能仅凭退出码归因节点。"
    if (timeout) print "- 存在超时：可能涉及节点、路由、上游、DNS 或服务；用总耗时和各阶段定位。"
    if (tls) print "- 存在 TLS 类错误：检查系统时间、证书信任、拦截和节点；不要关闭证书验证。"
    if (http) print "- 收到 401/403/429：可能为未登录端点、访问策略、风控或限流；匿名请求不能验证你的账号。"
    if (!dns && !tcp && !timeout && !tls) print "- 样本未出现上述常见传输错误；仍可能存在间歇性、长连接或应用专属问题。"
  }' "$scratch/results"
echo '【还需要进一步验证】'
echo '- 网络：两轮短请求未验证 SSE/WebSocket、HTTP/3、IPv6 差异或长时间稳定性；根路径可达不保证 Codex 后端正常。'
echo '- 登录认证：未读取凭据或执行真实登录。请记录失败发生在启动、浏览器登录、回跳还是发送任务阶段。'
echo '- 软件兼容性：对照上述系统/应用版本与官方当前支持要求；未检测签名、安装完整性或实际崩溃。'
echo '- 其他原因：账号权益/组织策略、服务事故、安全软件、浏览器扩展、应用自身故障仍需分别验证。'
echo
echo '八、下一步建议（本脚本不执行修改）'
echo '先把已确认观测和 Codex 的脱敏报错交给协助者，再决定是否做配置对照。'
echo '代理明显较好：优先核对 Clash 系统代理和应用是否使用它；暂不要自动切换 TUN。'
echo '代理也不稳定：先固定一个节点重复测试，结合实际登录和长回复验证，比较成功率、超时与抖动，不只看延迟。'
echo '需要修改时：先按 README 备份并约定恢复步骤；说明风险并获得你的确认后，一次只改一项。'
echo
echo "完成。报告仅保存在：$report"
echo '报告目录仅当前用户可读写。请勿把本机报告、应用原始日志或 Clash 配置提交 GitHub。'
