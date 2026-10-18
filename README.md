# Mac Codex 重连诊断（v2）

适用于 Mac + Clash Verge：网页能用，但桌面 Codex 在发送消息后反复「正在重新连接」。当前交付是**只读诊断工具**，不会自动修改代理、DNS、配置、证书或应用；没有宣称已修复。开发环境是 Linux 云端，不是你的 Mac。

## 第一次只执行一条命令

1. 打开 [GitHub 仓库](https://github.com/leah122122122/mac-network-config)，点 **Code → Download ZIP**，双击 ZIP 解压。请重新下载 v2 的完整文件夹，不能只替换单个 `.sh`，需要保留 `lib/`。
2. 按 **⌘＋空格**，输入「终端」打开。Clash 保持平时状态；你已试过系统代理和 TUN，这一轮无需再切换。
3. 粘贴下面**一条命令**并按回车（假设解压在默认「下载」文件夹，文件夹名没有变化）：

```bash
/bin/bash "$HOME/Downloads/mac-network-config-main/diagnose-codex.command"
```

如果提示找不到文件：在终端输入 `/bin/bash `（末尾一个空格），把解压文件夹的 **diagnose-codex.command** 拖进终端，再回车。路径包含空格也可以。无需 sudo、Git、Homebrew、Python、可执行权限或移除隔离属性。

`diagnose-codex.command` 是本地启动脚本；通过上述 bash 方式运行最稳妥。我们未在真实 Mac 上验证 Finder 双击、Gatekeeper 或浏览器下载行为，不要求关闭任何系统安全保护。

通常 4–12 分钟，大量超时时可更久；终端会显示进度。Control+C 可中止，中止报告不完整。桌面使用流量会和测试同时存在；请记下运行期间是否更换了网络/节点。

## 新版会检查什么

- macOS、架构、Rosetta 标记；常见目录中的 Codex、ChatGPT、Clash Verge 版本和应用声明的最低系统版本。自定义安装位置需手动补充；不执行应用中的程序。
- 当前 HTTP/HTTPS/SOCKS 系统代理、PAC 是否开启；不执行 PAC，不记录其 URL、远程代理地址、例外列表。
- 当前终端与用户 launchd 中**指定的代理变量**：只在内存中分类和比较，不把原值写入报告。检查大小写不同、作用域不同、可能的旧端口和 NO_PROXY 绕过。只查询具名变量，不导出整个环境、不读取应用进程环境。
- 自定义 CA 环境变量是否存在，路径和文件内容均不读取。`CODEX_HOME` 仅检查是否设置；默认配置文件只检查是否存在，不读正文。
- DNS 服务器和系统解析结果数量、Fake-IP 标记；utun 数量仅作提示，不认定它属于 Clash 或证明 TUN 已启用。
- 常见端口 **7897、7890、7891、1080、10808、10809** 及系统回环代理端口；优先 IPv4，失败时检查 IPv6 回环。TCP 可连接不证明是 Clash。
- 对比无显式代理、本机 HTTP、本机 SOCKS5h。每种协议选首个可访问 GitHub 的端口；如均失败，保留首个开放端口但标记「协议预检未验证」。也可以指定端口。
- HTTPS 默认三轮独立请求；记录 curl 退出码、HTTP 状态、DNS/TCP/TLS/首字节/总耗时及证书校验结果。
- Codex responses 端点的 IPv4/IPv6 对照；**显式代理路径的 -4/-6 通常只约束连接本机代理的地址族**，不代表代理出口的地址族。
- 对 Codex 和 OpenAI API responses 路径各做两次**匿名标准 WebSocket Upgrade 握手探测**，检查 101、Upgrade、Connection、随机键对应的 Sec-WebSocket-Accept 与 TLS 结果。不会改应用的 WebSocket/HTTP 选项。

固定目标包括 ChatGPT、OpenAI 当前及兼容登录域名、OpenAI API、GitHub 网页/API、`chatgpt.com/backend-api/codex/responses`，以及社区报告中的 `codex-cloud-backend.chatgpt.com` 根路径。最后一个是候选域名，根路径可达不能证明 durable 通道正常，也不代表你的发行版使用它。

## 三个必须区分的结果

| 层级 | 能证明什么 | 不能证明什么 |
| --- | --- | --- |
| HTTPS 收到响应 | 对该目标本次完成了传输并收到 HTTP 响应 | 登录有效、Plus 权限、模型回复、WebSocket 可用 |
| `握手=valid101` | 本次 TLS 与标准 Upgrade 响应校验成功，即使 curl 等待结束为 28 也可成立 | 业务帧、ping/pong、长时间稳定、真实已认证 Codex 通道 |
| 实际 Codex 回复成功 | 需你在桌面应用发送消息并确认 | 不能由匿名脚本代替验证 |

为了不读取令牌/Cookie，我们不做已认证握手、模型调用或 `codex doctor`，不自动读取应用日志、配置正文或钥匙串。**401/403/404/405/429 会经常出现在匿名端点；没有 valid101 时，一律写「握手未验证」，不会判成 WebSocket 被封锁或账号失效。**

工具利用系统 curl 发 HTTP/1.1 Upgrade，这正是 WebSocket 的标准握手形式；不要求系统 curl 支持 `wss://` 命令行协议。握手后不发送或解释业务帧，最长等待 8 秒；不是完整 WebSocket 客户端或持续连接测试。它与 Codex 的 Rust/Electron/其他组件网络栈不同。

## 报告在哪里、先发什么

报告分为「已经确认的观测」「可能存在的问题」「还需要进一步验证」。每次保存在本机：

```text
~/Library/Logs/mac-network-config/run-时间-随机字符/报告.txt
~/Library/Logs/mac-network-config/run-时间-随机字符/观测.tsv
```

Finder →「前往 → 前往文件夹」（Shift+⌘+G），输入 `~/Library/Logs/mac-network-config`，打开最新目录即可。TSV 的 route 是路径编号（0 为无显式代理，其他按报告顺序），target 为目标索引或 codex/api；索引顺序见报告第六节。每次报告与样本目录、文件由当前用户私有权限创建。

先把这些发给协助者：

1. **第七节「结论」**，以及第六节的失败行和匿名 Upgrade 行。
2. 你实际使用的是独立 Codex 还是 ChatGPT 中的 Codex，应用版本、报错原文和失败阶段。你已说明是发送消息后失败，请同时说明普通短消息是否也完全无法回复。
3. Clash Verge 模式、系统代理/TUN 当前状态，以及运行时的匿名节点编号（例如「日本 A」），不用再发订阅或节点地址。

可在 Mac 本地填写 [报告模板](REPORT_TEMPLATE.md)。报告末尾路径可能含用户名，DNS 地址也可能标识网络；分享前删掉用户名、私有/公网地址、邮箱及工作区信息。截图也要遮住账号信息。**不要发送订阅链接、密码、API Key、Cookie、访问令牌、登录回调 URL、完整配置或原始日志。**

## 正常与异常怎么读

| 观察 | 解释与下一步 |
| --- | --- |
| `curl=0` + HTTP 200/3xx | 本次收到响应；3xx 不跟随，重定向后的目标仍未验证。 |
| `curl=0` + HTTP 401/403/404/405/429 | 收到 HTTP 响应，认证/策略/路径/限流等仍未区分；不是完整业务成功。 |
| `curl=5/6` | 代理/目标解析类失败，系统 DNS 有结果仍不能排除代理端解析问题。 |
| `curl=7` | TCP 连接失败，结合本机端口与具体路径判断。 |
| `curl=28` 且握手未验证 | 超时；可能卡在解析、连接、TLS、上游或握手。若 valid101，则只记录为握手已完成后的等待上限，不能当成长连接故障。 |
| `curl=35/60` | TLS 握手/证书问题；核对时间、可信证书与网络拦截，绝不关闭校验。 |
| HTTP 000、证书=0 | 000 是没有有效状态；证书值 0 也可能是尚未进入校验阶段。必须一起看退出码和时序。 |
| 101 但没有 valid101 | 头部或 Accept 校验不完整，不能宣称握手正常。 |
| 同目标某轮响应、某轮超时 | 本次发现间歇性异常；特别是 7897 也失败时，先查节点/路由/上游，而非先注入变量。 |
| 终端与 launchd 值不同 | 已确认作用域差异；**不等于**已运行的 Codex 就具有该差异。不同版本优先级也可能不同。 |
| utun 存在 / Fake-IP 存在 | 可能正常；不能单独诊断 TUN 状态或 DNS 污染。 |

**无显式代理不保证物理直连**：TUN、其他 VPN 或透明网关仍可能接管。代理路径的 DNS/TCP 时间通常只描述本机代理，不能和直连逐项等同。两三轮短请求不能排除间歇性、服务端、账号、HTTP/3、SSE、durable 或真实长连接问题。

## 可选参数（首次不必用）

原入口 `diagnose-macos.sh` 仍可直接运行，启动脚本也支持相同参数。端口从 Clash 设置界面查看，不要复制配置。例如：

```bash
/bin/bash "$HOME/Downloads/mac-network-config-main/diagnose-codex.command" --http-port 7897 --socks-port 7897 --quick
```

Mixed 端口可同时验证两种协议，但测试通过不能保证 Codex 自身采用同样协议。参数仅接受 1–65535 数字，不接受远程地址或认证信息。`--quick` 把普通 HTTPS 改成两轮，WebSocket 仍两轮；`--help` 只显示帮助。代理认证或非回环监听不在自动探测范围内。

## 修复为什么暂时不执行

你已要求先拿到 Mac 结果再决定修复，本次没有提供可直接改配置的修复入口。详见 [技术研究](docs/RESEARCH.md) 和 [待确认的修复与恢复方案](docs/REPAIR_PLAN.md)。上游源码有开发中 `respect_system_proxy` 功能，不等于目标桌面版本的稳定官方修复；社区全局 launchctl 方案也会影响其他 GUI 应用。

下一步根据本机证据选择一项最小对照。只有核对版本和支持范围、列出具体变更及风险、先备份并提供恢复步骤、得到你逐项确认后，才考虑制作和执行单独修复程序。不改变 provider、base URL、WebSocket transport，不改应用内部，不先清理登录状态、重装或重置网络。

节点优化优先看成功率、超时、抖动、稳定出口和实际长回复。已开启系统代理、TUN 也失败时，不重复建议盲目打开 TUN。规则与 DNS 对照以真实路径证据为依据，一次只变一项，保留原配置；不要上传备份。

## 安全与开发验证

脚本只写本机报告及临时文件，不改网络、launchd、Codex 配置、订阅或应用。临时文件正常退出会删除。HTTP 头实时经过白名单解析器，只保留数字与握手布尔结果；Set-Cookie、Location、其他响应头、正文和原始错误不写入磁盘。代理变量的值只在内存中分类、比较，从不输出；不会查阅密钥环境变量或认证文件。

网络请求忽略 `.curlrc`、继承的代理与自定义 CA 环境，使用系统信任、开启 TLS 验证；只影响诊断子进程，不改原终端或应用。目标服务会看到出口 IP，报告不记录出口 IP、不自动上传。它与使用自定义 CA 的 Codex 结果可能不同，报告会提示差异。`.gitignore` 只是防误提交，不能阻止手动或强制上传。

开发者可运行 `python3 tests/test_diagnostics.py`；普通用户不用安装 Python。测试只使用临时目录和模拟网络，**不发公网请求**。测试与代码审查范围见 [VALIDATION.md](docs/VALIDATION.md)。尚未在真实 macOS 上端到端运行，不能把云端模拟结果说成你的本机结果或宣称问题已修复。
