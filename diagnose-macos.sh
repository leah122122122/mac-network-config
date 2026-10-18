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
Codex 重连只读诊断 v2；--quick 使用两轮采样（默认三轮）。
只读诊断，报告保存到本机 ~/Library/Logs/mac-network-config/。
可选端口只能指向本机 127.0.0.1；不支持代理密码或远程代理。
--help 显示说明，不执行诊断。按 Control+C 可停止。
EOF
}
http_override=''; socks_override=''; samples=3
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --quick) samples=2; shift ;;
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
for tool in curl scutil sw_vers nc awk mktemp tee dscacheutil openssl launchctl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "缺少系统工具：$tool；已停止。" >&2; exit 1; }
done
[ "$(id -u)" -ne 0 ] || { echo '请以普通用户运行，不要使用 sudo。' >&2; exit 1; }

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 1
for file in env-check.sh response.awk findings.awk; do
  [ -f "$script_dir/lib/$file" ] || { echo '文件不完整：请下载并解压整个仓库 ZIP。' >&2; exit 1; }
done
report_root="$HOME/Library/Logs/mac-network-config"
mkdir -p "$report_root" || exit 1
report_dir=$(mktemp -d "$report_root/run-$(date +%Y%m%d-%H%M%S)-XXXXXX") || exit 1
report="$report_dir/报告.txt"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mac-network-diag.XXXXXX") || exit 1
active_child=''; active_guard=''
cleanup() {
  [ -z "$active_child" ] || kill -TERM "$active_child" 2>/dev/null || :
  [ -z "$active_guard" ] || kill -TERM "$active_guard" 2>/dev/null || :
  rm -rf "$scratch"
}
trap cleanup EXIT
trap 'echo "诊断已中止，现有报告不完整。"; exit 130' INT TERM
exec > >(tee "$report") 2>&1

# Some native resolver commands have no timeout flag. Kill only this child.
bounded() {
  local limit=$1 result
  shift
  "$@" > "$scratch/bounded.out" 2>/dev/null & active_child=$!
  ( sleep "$limit"; kill -TERM "$active_child" 2>/dev/null ) & active_guard=$!
  wait "$active_child" 2>/dev/null; result=$?
  kill "$active_guard" 2>/dev/null || :
  wait "$active_guard" 2>/dev/null || :
  active_child=''; active_guard=''
  cat "$scratch/bounded.out"
  return "$result"
}
value() { awk -v key="$1" '$1 == key && $2 == ":" {print $3; exit}' "$scratch/proxy"; }
is_loopback() { case "$1" in 127.0.0.1|localhost|::1) return 0;; *) return 1;; esac; }
valid_port() { case "$1" in ''|*[!0-9]*) return 1;; esac; [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

echo 'macOS / Codex 重连只读诊断 v2.0'
echo "执行地点：当前运行脚本的 Mac；时间：$(date '+%Y-%m-%d %H:%M:%S %z')"
echo '不修改配置，不读取订阅、密码、钥匙串、Cookie、登录文件或应用日志，不上传报告。'
echo '将向固定的 OpenAI / ChatGPT / GitHub 域名发送无登录 HTTPS 请求；服务商会看到出口 IP。'
echo '预计 4–12 分钟，超时较多时更久。按 Control+C 可停止。'
echo '分享前请检查 DNS 服务器地址、系统版本、时间等信息；不要公开上传整份报告。'
echo
echo '一、系统与应用元数据'
echo "系统 curl：$(/usr/bin/curl -q --version | head -1)"
echo '时间仅供人工核对；未查询时间服务器，不能自动判断系统时钟偏差。'
os_version=$(sw_vers -productVersion)
arch=$(uname -m)
echo "macOS：$os_version；当前进程架构：$arch；内核：$(uname -r)"
arm_capable=$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)
translated=$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)
echo "Apple Silicon 能力标记：$arm_capable；Rosetta 转译标记：$translated"
echo '架构标记只能辅助排查兼容性；未据此判断 Codex 支持哪些系统。'
app_found=0; compat_problem=0
for app in /Applications/Codex.app "$HOME/Applications/Codex.app" /Applications/ChatGPT.app "$HOME/Applications/ChatGPT.app" "/Applications/Clash Verge.app" "$HOME/Applications/Clash Verge.app"; do
  app_name=$(basename "$app" .app)
  plist="$app/Contents/Info.plist"
  [ -f "$plist" ] || continue
  app_found=1
  for key in CFBundleShortVersionString CFBundleVersion LSMinimumSystemVersion; do
    v=$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || :)
    # Only version strings; never print paths or arbitrary plist values.
    case "$v" in ''|*[!0-9A-Za-z.+_-]*) v='未提供或格式未识别';; esac
    echo "$app_name $key：$v"
    if [ "$key" = LSMinimumSystemVersion ] && [ "$app_name" != "Clash Verge" ]; then
      case "$v" in
        ''|*[!0-9.]*) : ;;
        *)
          if awk -v current="$os_version" -v minimum="$v" 'BEGIN {split(current,a,"."); split(minimum,b,"."); for(i=1;i<=3;i++) {if(a[i]+0<b[i]+0) exit 0; if(a[i]+0>b[i]+0) exit 1} exit 1}'; then
            compat_problem=1
            echo "兼容性观测：系统版本低于 $app_name 声明的最低版本。"
          fi ;;
      esac
    fi
  done
done
[ "$app_found" -eq 1 ] || echo '常见安装目录未找到上述应用；自定义位置需手动补充。'
if [ -n "${CODEX_HOME-}" ]; then
  echo 'CODEX_HOME 已设置（路径隐藏）；不读取自定义目录或配置。'
elif [ -e "$HOME/.codex/config.toml" ]; then
  echo '默认 config.toml 存在；可能含凭据，不读取正文或自动检查配置键。'
else echo '默认 config.toml 不存在；其他位置或受管配置未知。'; fi
echo
echo '二、当前生效的系统代理（scutil；不输出远程地址或 PAC URL）'
scutil --proxy 2>/dev/null | awk '
  $2==":" && $1~/^(HTTP|HTTPS|SOCKS)Proxy$/ {
    if($3=="127.0.0.1" || $3=="localhost" || $3=="::1") print $1,":",$3
    else print $1,": REMOTE_REDACTED"
  }
  $2==":" && $1~/^((HTTP|HTTPS|SOCKS)Enable|ProxyAutoConfigEnable|ProxyAutoDiscoveryEnable)$/ {
    if($3~/^[01]$/) print $1,":",$3
  }
  $2==":" && $1~/^(HTTP|HTTPS|SOCKS)Port$/ && $3~/^[0-9]+$/ {print $1,":",$3}
' > "$scratch/proxy"
for kind in HTTP HTTPS SOCKS; do
  enabled=$(value "${kind}Enable"); host=$(value "${kind}Proxy"); port=$(value "${kind}Port")
  if is_loopback "$host"; then display='本机回环地址'; elif [ -n "$host" ]; then display='非回环地址（已隐藏）'; else display='未提供'; fi
  valid_port "$port" || port='未提供'
  echo "$kind：启用=${enabled:-0/未提供}；服务器=$display；端口=$port"
done
echo "PAC 自动配置：$(value ProxyAutoConfigEnable)；自动发现：$(value ProxyAutoDiscoveryEnable)（空值表示未提供）"
echo 'PAC 脚本、例外列表和远程代理不会被读取或执行；这里只检测本机代理。'
. "$script_dir/lib/env-check.sh"
inspect_proxy_environment
echo '注意：curl 不自动遵循 macOS 系统代理/PAC；下面显式指定每条测试路径。'
echo
echo '三、DNS 配置与系统解析'
scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/ {print "DNS 服务器（本地记录，分享前检查）：" $3} /flags[ ]*:/ {print "解析器 " $0}' | head -60
targets=(chatgpt.com auth.openai.com auth0.openai.com api.openai.com github.com api.github.com codex-cloud-backend.chatgpt.com)
dns_total=${#targets[@]}
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
tun_count=$(ifconfig -l 2>/dev/null | awk '{n=0;for(i=1;i<=NF;i++) if($i~/^utun[0-9]+$/) n++; print n}')
echo "utun 接口数量=${tun_count:-未知}；不能证明是 Clash、TUN 已启用或应用路由。"
echo 'codex-cloud-backend 为社区报告涉及的候选域名；当前版本是否使用它未知。'
echo '四、本机常见代理端口（TCP 探测，不读取进程或 Clash 配置）'
ports=(7897 7890 7891 1080 10808 10809)
for kind in HTTP HTTPS SOCKS; do
  host=$(value "${kind}Proxy"); port=$(value "${kind}Port")
  if is_loopback "$host" && valid_port "$port"; then ports+=("$port"); fi
done
[ -z "$http_override" ] || ports+=("$http_override")
[ -z "$socks_override" ] || ports+=("$socks_override")
open_ports=(); open_hosts=(); seen=' '
for port in "${ports[@]}"; do
  case "$seen" in *" $port "*) continue;; esac
  seen="$seen$port "
  if nc -z -G 1 -w 1 127.0.0.1 "$port" >/dev/null 2>&1; then
    echo "127.0.0.1:$port：TCP 可连接（尚未证明是 Clash 或代理）"
    open_ports+=("$port")
    open_hosts+=(127.0.0.1)
  elif nc -6 -z -G 1 -w 1 ::1 "$port" >/dev/null 2>&1; then
    echo "[::1]:$port：IPv6 TCP 可连接（尚未证明是 Clash 或代理）"
    open_ports+=("$port"); open_hosts+=('[::1]')
  else
    echo "回环端口 $port：IPv4/IPv6 TCP 均不可连接"
  fi
done
echo '优先 IPv4 回环，不可连接时尝试 ::1；非回环地址或需认证的代理请手动核对。'
proxy_host_for_port() {
  local i
  proxy_host=127.0.0.1
  for ((i=0;i<${#open_ports[@]};i++)); do
    if [ "${open_ports[$i]}" = "$1" ]; then proxy_host=${open_hosts[$i]}; break; fi
  done
}

# curl -q disables ~/.curlrc. env removes inherited proxy credentials/routing.
# No redirects, raw header/body recording, cookies, auth, -k or verbose errors.
request() {
  local route=$1 url=$2 limit=$3 mode=${4:-https} family=${5:-auto} nonce='' expected=''
  local args=() extra=() statuses=()
  if [ "$route" = direct ]; then args=(--proxy '' --noproxy '*'); else args=(--proxy "$route" --noproxy ''); fi
  case "$family" in v4) extra+=(-4);; v6) extra+=(-6);; esac
  if [ "$mode" = ws ]; then
    nonce=$(openssl rand -base64 16 2>/dev/null) || return 1
    expected=$(printf '%s' "${nonce}258EAFA5-E914-47DA-95CA-C5AB0DC85B11" | openssl dgst -sha1 -binary 2>/dev/null | openssl base64 2>/dev/null) || return 1
    [ -n "$nonce" ] && [ -n "$expected" ] || return 1
    extra+=(--http1.1 --header 'Connection: Upgrade' --header 'Upgrade: websocket' --header 'Sec-WebSocket-Version: 13' --header "Sec-WebSocket-Key: $nonce")
  fi
  /usr/bin/env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u no_proxy -u NO_PROXY -u WS_PROXY -u WSS_PROXY \
    -u CODEX_CA_CERTIFICATE -u SSL_CERT_FILE -u SSL_CERT_DIR -u CURL_CA_BUNDLE \
    /usr/bin/curl -q --silent --output /dev/null --dump-header - --connect-timeout 5 --max-time "$limit" \
    --proto '=https' "${args[@]}" "${extra[@]}" \
    --write-out '\nMNC_METRICS %{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{ssl_verify_result}\n' \
    "$url" 2>/dev/null | awk -v expected="$expected" -f "$script_dir/lib/response.awk" > "$scratch/measurement"
  statuses=("${PIPESTATUS[@]}")
  curl_rc=${statuses[0]}; parser_rc=${statuses[1]}
  read -r code dns tcp tls first total verify status upgrade connection accept metrics_ok < "$scratch/measurement"
  if [ "$parser_rc" -ne 0 ] || [ "$metrics_ok" != 1 ]; then
    code=000; dns=0; tcp=0; tls=0; first=0; total=0; verify=999; status=000
  fi
  handshake='not-tested'
  if [ "$mode" = ws ]; then
    handshake='unverified'
    if [ "$code" = 101 ] && [ "$status" = 101 ] && [ "$upgrade" = 1 ] && [ "$connection" = 1 ] && [ "$accept" = 1 ] && [ "$verify" = 0 ] && awk -v t="$tls" 'BEGIN {exit !(t+0>0)}'; then
      handshake='valid101'
    fi
  fi
  return 0
}

routes=(direct); labels=('不使用显式代理')
http_selected=''; socks_selected=''; protocol_verified=0
echo
echo '五、代理协议验证（GitHub HTTPS；成功仅表示这一时刻该目标可达）'
for protocol in http socks5h; do
  if [ "$protocol" = http ]; then override=$http_override; else override=$socks_override; fi
  if [ -n "$override" ]; then candidates=("$override"); else candidates=("${open_ports[@]}"); fi
  for port in "${candidates[@]}"; do
    proxy_host_for_port "$port"
    request "$protocol://$proxy_host:$port" https://github.com/ 6
    echo "$protocol 端口 $port：curl=$curl_rc，HTTP=$code"
    if [ "$curl_rc" -eq 0 ] && [ "$code" != 000 ]; then
      protocol_verified=$((protocol_verified+1))
      routes+=("$protocol://$proxy_host:$port"); labels+=("$protocol $proxy_host 本机端口 $port")
      if [ "$protocol" = http ]; then http_selected=$port; else socks_selected=$port; fi
      break
    fi
  done
  if { [ "$protocol" = http ] && [ -z "$http_selected" ]; } || { [ "$protocol" = socks5h ] && [ -z "$socks_selected" ]; }; then
    fallback=$override
    if [ -z "$fallback" ] && [ "${#open_ports[@]}" -gt 0 ]; then fallback=${open_ports[0]}; fi
    if [ -n "$fallback" ]; then
      proxy_host_for_port "$fallback"
      routes+=("$protocol://$proxy_host:$fallback"); labels+=("$protocol $proxy_host 本机端口 $fallback（协议预检未验证，保留对照）")
    fi
  fi
done
echo '每种协议选首个可访问 GitHub 的端口；均失败时保留首个开放端口对照（协议未验证）。可用参数指定实际端口。'
echo
echo "六、HTTPS 与 WebSocket 原始观测（HTTPS $samples 轮；无账号）"
echo '不使用显式代理 ≠ 物理直连：Clash TUN、其他 VPN、透明路由可能仍接管。'
echo '累计耗时单位为秒：DNS / TCP / TLS / 首字节 / 总计。代理路径 DNS/TCP 常只反映本机代理，不能与直连逐项等同。'
echo 'HTTP 401/403/404/429 可证明收到 HTTP 响应，但不能证明登录、地区权限或 Codex 功能正常。'
echo '端点说明：ChatGPT 网页、当前/兼容登录域名、OpenAI API、GitHub 网页/API；不是完整 Codex 会话。'
urls=(https://chatgpt.com/ https://auth.openai.com/ https://auth0.openai.com/ https://api.openai.com/v1/models https://github.com/ https://api.github.com/ https://codex-cloud-backend.chatgpt.com/)
targets+=(chatgpt.com)
urls+=(https://chatgpt.com/backend-api/codex/responses)
echo '另测 Codex responses 路径；401/403/404/405 可出现，不是已认证 API 功能测试。'
deep_results="$report_dir/观测.tsv"
printf '# route target round kind family curl http total handshake\n' > "$deep_results"
: > "$scratch/results"
for ((r=0; r<${#routes[@]}; r++)); do
  echo
  echo "路径：${labels[$r]}"
  for ((h=0; h<${#targets[@]}; h++)); do
    for ((round=1; round<=samples; round++)); do
      request "${routes[$r]}" "${urls[$h]}" 12
      echo "${urls[$h]} 第$round轮：curl=$curl_rc HTTP=$code；DNS=$dns TCP=$tcp TLS=$tls 首字节=$first 总计=$total；证书校验=$verify"
      echo "$r $h $round $curl_rc $code $total" >> "$scratch/results"
      if [ "${urls[$h]}" = https://chatgpt.com/backend-api/codex/responses ]; then target=codex; else target=$h; fi
      echo "$r $target $round https auto $curl_rc $code $total not-tested" >> "$deep_results"
    done
  done
  for family in v4 v6; do
    request "${routes[$r]}" https://chatgpt.com/backend-api/codex/responses 8 https "$family"
    echo "Codex 地址族=$family：curl=$curl_rc HTTP=$code DNS=$dns TCP=$tcp TLS=$tls 总计=$total 证书=$verify"
    echo "$r codex 1 https $family $curl_rc $code $total not-tested" >> "$deep_results"
  done
  echo '代理路径的 -4/-6 一般只约束到本机代理，不验证上游地址族；不可由此建议关闭 IPv6。'
  for ws_url in https://chatgpt.com/backend-api/codex/responses https://api.openai.com/v1/responses; do
    if [ "$ws_url" = https://chatgpt.com/backend-api/codex/responses ]; then target=codex; else target=api; fi
    for round in 1 2; do
      if request "${routes[$r]}" "$ws_url" 8 ws; then
        echo "匿名标准 Upgrade $ws_url 第$round轮：curl=$curl_rc HTTP=$code TLS=$tls 总计=$total 证书=$verify 握手=$handshake"
        echo "$r $target $round ws auto $curl_rc $code $total $handshake" >> "$deep_results"
      else echo '随机握手键生成失败，此次 WebSocket 探测跳过，未得出结论。'; fi
    done
  done
  echo 'Upgrade 是 wss 的标准握手，不修改应用传输；不发送业务帧或验证长时间连接。'
done
echo
echo '七、结论（仅针对这次本机样本）'
echo '【已经确认的观测】'
[ "$compat_problem" -eq 0 ] || echo '软件兼容性：当前 macOS 低于已找到应用声明的最低系统版本，需要核对安装包与官方支持要求。'
echo "系统 DNS 未返回地址的域名数：$dns_failed / $dns_total。这不等同于已经确认 DNS 故障原因。"
for ((r=0; r<${#routes[@]}; r++)); do
  summary=$(awk -v r="$r" '$1==r {n++; if($4==0 && $5!="000") ok++; else fail++; if($4==28) timeout++; if($4==35 || $4==60) tls++; if($4==5 || $4==6) dns++} END {printf "HTTP响应 %d/%d；传输失败 %d；超时 %d；TLS类错误 %d；解析类错误 %d",ok,n,fail,timeout,tls,dns}' "$scratch/results")
  echo "${labels[$r]}：$summary"
done
[ "$protocol_verified" -gt 0 ] || echo '未自动验证可用的本机代理路径；不能据此判定节点无效（也可能端口不同或 GitHub 被单独阻断）。'
echo "环境差异项=$env_differences；代理变量的本机 IPv4 端口不可连接项=$env_closed；NO_PROXY 粗查命中项=$env_bypass。"
awk -f "$script_dir/lib/findings.awk" "$deep_results"
[ "$env_differences" -eq 0 ] || echo '- 终端/launchd 或大小写变量有差异：核对启动来源；launchd 不是当前应用环境快照，不应直接全局 setenv。'
[ "$env_closed" -eq 0 ] || echo '- 代理变量端口不可连接：可能旧端口残留，需核对后才考虑清理。'
[ "$env_bypass" -eq 0 ] || echo '- NO_PROXY 可能让 OpenAI 域名绕过代理，需核对真实匹配规则，不自动删除。'
[ "$env_custom_ca" -eq 0 ] || echo '- 存在自定义 CA 环境；探测用系统信任，Codex 结果可能不同。只核对可信来源，不自动读取或安装证书。'
echo '【还需要进一步验证】'
echo '- 网络：未验证已认证模型流、durable/app-server 通道、SSE、HTTP/3 或长时间稳定性；匿名探测不能等同完整 Codex。'
echo '- 登录认证：未读取凭据或执行真实登录。请记录失败发生在启动、浏览器登录、回跳还是发送任务阶段。'
echo '- 软件兼容性：对照上述系统/应用版本与官方当前支持要求；未检测签名、安装完整性或实际崩溃。'
echo '- 其他原因：账号权益/组织策略、服务事故、安全软件、浏览器扩展、应用自身故障仍需分别验证。'
echo
echo '八、下一步建议（本脚本不执行修改）'
echo '先把已确认观测和 Codex 的脱敏报错交给协助者，再决定是否做配置对照。'
echo '代理明显较好：优先核对 Clash 系统代理和应用是否使用它；暂不要自动切换 TUN。'
echo '代理也不稳定：先固定一个节点重复测试，结合实际登录和长回复验证，比较成功率、超时与抖动，不只看延迟。'
echo '上游源码的 respect_system_proxy 仍在开发中；未核对你的版本支持，不自动添加，更不误写成复数。'
echo '需要修改时：先按 README 备份并约定恢复步骤；说明风险并获得你的确认后，一次只改一项。'
echo
echo "完成。报告仅保存在：$report"
echo '同目录 观测.tsv 为脱敏后的数值样本；分享前仍请人工检查。'
echo '报告目录仅当前用户可读写。请勿把本机报告、应用原始日志或 Clash 配置提交 GitHub。'
