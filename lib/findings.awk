# Input: route target round kind family curl status total handshake
{
  if($4=="https" && $5=="auto") {
    key=$1 ":" $2
    if($6==0 && $7!="000") good[key]++; else bad[key]++
    if($2=="codex") {if($6==0 && $7!="000") codexgood[$1]++; else codexbad[$1]++}
  }
  if($6==5 || $6==6) dns++
  if($6==7) tcp++
  if($6==28 && $9!="valid101") timeout++
  if($6==35 || $6==60) tls++
  if($4=="ws") {
    ws++
    if($9=="valid101") valid++
    else if($7==401 || $7==403 || $7==407) rejected++
    else if($7==101) invalid++
  }
  if($4=="https" && $2=="codex" && $5=="v4" && $6==0 && $7!="000") v4[$1]=1
  if($4=="https" && $2=="codex" && $5=="v6" && $6!=0) v6bad[$1]=1
}
END {
  print "【可能存在的问题与证据】"
  for(k in good) if(bad[k]>0) {print "- 同一路径/目标出现成功与失败混合：本轮观察到间歇性传输异常。"; break}
  if(codexbad[0]>0) for(r in codexgood) if(r!=0 && codexgood[r]>0) {print "- Codex 端点代理路径收到响应、无显式代理有失败：应用代理路由差异值得核对，不能证明应用实际走了哪条路径。"; break}
  if(dns) print "- 存在 curl 解析类错误：优先区分本机解析与代理端解析，不能由系统解析有结果就排除 DNS。"
  if(tcp) print "- 存在 TCP/代理连接失败：核对对应端口与路径；单独端口探测不能确认监听者身份。"
  if(timeout) print "- 存在未验证握手的超时：7897 路径也超时的话，先比较节点/路由和上游稳定性，不宜仅注入更多代理变量。"
  if(tls) print "- 存在 TLS 类失败：核对系统时间、可信证书、网络拦截和应用 TLS 栈差异；不要关闭校验。"
  if(invalid) print "- 收到 101 但 Upgrade/Connection/Accept 校验不完整：未验证有效 WebSocket 握手；核对网关或测试工具兼容性。"
  for(r in v4) if(v6bad[r]) print "- 路径 " r " 的 IPv4 收到响应而 IPv6 失败：只说明该次受测路径的地址族差异；代理路径仅测试连接本机代理的地址族。不要据此关闭系统 IPv6。"
  print "【WebSocket 的实测范围】"
  printf "- 匿名 Upgrade 探测 %d 次；有效 101 握手 %d 次；认证/策略拒绝 %d 次。\n",ws,valid,rejected
  if(!valid) print "- 未验证任何有效 WebSocket 握手；401/403、404、超时都不能分别证明账号失效或 WebSocket 被封锁。"
  else print "- 有效 101 只证明这一时刻完成握手；本工具不发业务帧、不验证 ping/pong 或持续连接稳定性。"
  print "- 不读取登录凭据，因此已认证 Codex 模型流、durable/app-server 通道、SSE 与真实长回复都仍需本机应用验证。"
}
