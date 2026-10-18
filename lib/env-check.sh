# Sourced by diagnose-macos.sh. Values stay in memory and never enter reports.
# Inspect only named proxy variables; never enumerate the full environment.
env_differences=0; env_closed=0; env_bypass=0; env_custom_ca=0
proxy_names=(HTTP_PROXY http_proxy HTTPS_PROXY https_proxy ALL_PROXY all_proxy NO_PROXY no_proxy WS_PROXY WSS_PROXY)

describe_proxy_value() {
  local raw=$1 regex protocol port
  description='已设置，值隐藏；格式/远程地址/认证信息不展开'
  [ -n "$raw" ] || { description='未设置或为空'; return; }
  regex='^(http|https|socks5|socks5h)://(127\.0\.0\.1|localhost|\[::1\]):([0-9]{1,5})/?$'
  if [[ "$raw" =~ $regex ]]; then
    protocol=${BASH_REMATCH[1]}; port=${BASH_REMATCH[3]}
    if valid_port "$port"; then
      description="$protocol 本机端口 $port"
      # IPv6-only is not a closed-port finding; it needs separate verification.
      if [[ "$raw" == *'[::1]'* ]]; then
        description="$description（IPv6 回环，未验证）"
      elif nc -z -G 1 -w 1 127.0.0.1 "$port" >/dev/null 2>&1; then
        description="$description（TCP 可连接）"
      else
        description="$description（IPv4 TCP 不可连接；localhost 的 IPv6 情况未知）"
        env_closed=$((env_closed+1))
      fi
    fi
  fi
}

inspect_proxy_environment() {
  local name i upper lower value
  local shell_values=() launch_values=()
  echo '代理环境变量（仅分类，原值不写入文件）'
  for name in "${proxy_names[@]}"; do
    value=${!name-}
    shell_values+=("$value")
    value=$(launchctl getenv "$name" 2>/dev/null || :)
    launch_values+=("$value")
  done
  for ((i=0; i<${#proxy_names[@]}; i++)); do
    name=${proxy_names[$i]}
    case "$name" in
      NO_PROXY|no_proxy)
        for value in "${shell_values[$i]}" "${launch_values[$i]}"; do
          case "$value" in
            '*'|*chatgpt.com*|*openai.com*) env_bypass=$((env_bypass+1));;
          esac
        done
        [ -z "${shell_values[$i]}" ] && upper='未设置或为空' || upper='已设置（列表隐藏）'
        [ -z "${launch_values[$i]}" ] && lower='未设置或为空' || lower='已设置（列表隐藏）'
        ;;
      *)
        describe_proxy_value "${shell_values[$i]}"; upper=$description
        describe_proxy_value "${launch_values[$i]}"; lower=$description
        ;;
    esac
    echo "$name：当前终端=$upper；用户 launchd=$lower"
    if [ "${shell_values[$i]}" != "${launch_values[$i]}" ]; then
      env_differences=$((env_differences+1))
      echo '  观测：终端与 launchd 的值不同；不等于已经运行的应用环境不同。'
    fi
  done
  for ((i=0; i<6; i+=2)); do
    if [ -n "${shell_values[$i]}" ] && [ -n "${shell_values[$((i+1))]}" ] && [ "${shell_values[$i]}" != "${shell_values[$((i+1))]}" ]; then
      env_differences=$((env_differences+1)); echo "终端 ${proxy_names[$i]} 大小写值不同（潜在冲突）。"
    fi
    if [ -n "${launch_values[$i]}" ] && [ -n "${launch_values[$((i+1))]}" ] && [ "${launch_values[$i]}" != "${launch_values[$((i+1))]}" ]; then
      env_differences=$((env_differences+1)); echo "launchd ${proxy_names[$i]} 大小写值不同（潜在冲突）。"
    fi
  done
  echo 'WS_PROXY/WSS_PROXY 只检查是否设置，不代表目标 Codex 版本支持这些名称。'
  for name in CODEX_CA_CERTIFICATE SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE; do
    if [ -n "${!name-}" ] || [ -n "$(launchctl getenv "$name" 2>/dev/null || :)" ]; then
      echo "$name：存在自定义证书环境设置（路径和内容隐藏，未读取文件）"
      env_custom_ca=$((env_custom_ca+1))
    fi
  done
  echo 'launchd 查询失败与未设置可能无法区分；它不是已运行 Codex 的环境快照。'
  echo 'NO_PROXY 仅粗查通配符和 OpenAI 域名字样；未完整解释 CIDR、大小写和全部匹配规则。'
  echo '所有网络探测均清除代理/自定义 CA 环境对该子进程的影响，保留系统 TLS 验证；不改变原终端或应用环境。'
}
