# Codex 桌面重连：技术研究与证据等级

核查日期：2026-10-18（北京时间）。你的具体应用版本尚未知。公开主分支不等于已安装桌面构建；文档也可能更新或重定向。以下没有把社区报告中的“成功”当作你的 Mac 已修复。

## 1. 官方文档确认的范围

OpenAI 的 [网络建议](https://help.openai.com/en/articles/9247338-network-recommendations-for-chatgpt-errors-on-web-and-apps) 明确：部分 ChatGPT/Codex 功能除 HTTPS 外还使用安全 WebSocket；Codex 模型采样与流式传输涉及 `wss://chatgpt.com/` 的 TCP 443 和标准 Upgrade。代理/防火墙应允许握手与后续连接，排查 TLS 检查、空闲超时及帧/消息大小限制。这支持“网页正常仍可能有 Codex 通道问题”，但没有给出适用于所有 Mac 重连的单键修复。

[配置基础](https://developers.openai.com/codex/config-basic) 说明用户配置通常为 `~/.codex/config.toml`，也可能有项目、profile、系统与受管层。只看默认文件不能代表有效配置。本工具为避免读取其中凭据，只检查存在性，不执行 Codex、读取配置正文或登录文件。

[配置参考](https://developers.openai.com/codex/config-reference) 公开了 provider 的 `supports_websockets`、`wire_api`、`stream_idle_timeout_ms` 和 `stream_max_retries` 等。SSE 的超时/重试选项不等于所有 WebSocket/durable 通道的参数。更改 provider 或禁止 WebSocket 可能改变模型能力或失败行为，不能作为通用重连修复，本项目不会这样操作。

[App Server 文档](https://developers.openai.com/codex/app-server) 涉及客户端与 app-server、stdio/WebSocket/Unix socket 等控制连接；这些与模型 Responses 流不是同一个层次。文档所述某些 WebSocket 模式仍是实验性的，不能将某个 app-server 示例或本地监听测试直接当作桌面全部网络路径。

## 2. 官方公开源码能确认的实现（不是稳定支持承诺）

核查主分支提交 [`8c076942cb70fba8e5c4732c23f1faabc4aed484`](https://github.com/openai/codex/commit/8c076942cb70fba8e5c4732c23f1faabc4aed484)。桌面界面及不同组件不保证完全采用相同客户端、代理优先级和发布时点。

| 问题 | 源码证据与边界 |
| --- | --- |
| macOS 系统代理是否支持？ | [features 注册表](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/features/src/lib.rs) 存在 `respect_system_proxy`（单数），标为 UnderDevelopment、默认 false。这证明源码有功能，不能保证任意桌面版本支持，也不能由系统代理开启推断所有请求都采用它。 |
| 代理环境是否适用？ | [outbound_proxy](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/http-client/src/outbound_proxy.rs) 定义默认传输与系统代理策略。系统策略可将 wss 目标映射到 https 进行代理解析；不可用时才回退环境。具体 HTTPS/WSS 的变量选择和默认传输仍依路径而异，不能简单称“环境一定优先”。 |
| WebSocket 怎样使用代理？ | [websocket-client](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/websocket-client/src/lib.rs) 与 [dialer](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/websocket-client/src/dialer.rs) 共用 HTTP 工厂的路由策略；默认 dialer 涉及 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY/NO_PROXY。也有 TLS 到代理的处理分支，但协议解析与系统代理发现仍存在平台差别。不能保证 SOCKS、PAC 和每个桌面组件等价。 |
| TLS/自定义证书？ | [custom_ca](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/http-client/src/custom_ca.rs) 提供 HTTP/WebSocket 共用的自定义 CA 支持，涉及 CODEX_CA_CERTIFICATE、SSL_CERT_FILE。是否已发布到你的组件未知；curl 与应用 TLS 栈仍可能不同。项目不会关闭校验、读取证书文件或自动信任未知 CA。 |
| 能不能只探握手？ | [Responses WebSocket 代码](https://github.com/openai/codex/blob/8c076942cb70fba8e5c4732c23f1faabc4aed484/codex-rs/codex-api/src/endpoint/responses_websocket.rs) 有 handshake-only probe，但采用有效 provider/认证来源。安全要求不允许本工具读认证，因此不执行它、不调用 doctor 来间接加载凭据。 |

这里的 `HTTPS_PROXY=http://127.0.0.1:7897` 表示 HTTPS 目标通过本机 **HTTP CONNECT** 代理，目标 TLS 仍开启；不是把目标改成明文 HTTP。`https://` 代理 URL 则是到代理本身也使用 TLS，不能凭变量名称混用。SOCKS5h 可以把域名解析交给代理，但 curl 成功只证明 curl 的这条路径；不能推断桌面组件的协议支持和路由。

终端 `export` 只影响该 shell 及其后代，不能给已经运行的应用补变量。Finder/Dock 启动方式、用户 launchd 环境与应用启动时刻可能不同。本工具只比较终端和当前 launchd 的指定变量，不读取已运行应用环境，不证明真实继承情况。不把 WS_PROXY/WSS_PROXY 或 `.codex/.env` 当作全部桌面版本公开承诺的代理接口。

## 3. 社区一手故障报告（不是官方确认的通用修复）

- [#30695：Finder 启动与代理环境](https://github.com/openai/codex/issues/30695)：报告者称导入用户 launchd 代理后恢复。该操作会影响其他 GUI 应用且现有进程不自动更新；不作为默认修复。
- [#39237：配置键单复数](https://github.com/openai/codex/issues/39237)：最初报告使用复数键，后续用户更正为单数并报告成功。这说明要读完整讨论、核对版本；不能只读标题得出“不支持系统代理”。仍不能证明你缺少同一设置。
- [#51399：网页正常、桌面 durable 1006](https://github.com/openai/codex/issues/51399)：截至核查页面仍为 Open；报告涉及 ChatGPT 内 Codex、系统代理和 TUN 均无效，并有 HTTPS 正常但 durable 失败的情况。`codex-cloud-backend.chatgpt.com` 来自讨论，不是本工具确认的所有版本固定端点。后续用户同时更改多项配置的恢复也不能隔离出根因。
- [#40435：不可达的自定义 base URL](https://github.com/openai/codex/issues/40435)：提示配置覆盖可表现为连接错误。不能因此删除你可能有意设置的 provider/base URL；本工具也不读配置正文来猜测。

社区提供了可验证的假设：应用没有走预期代理、残留旧端口、自定义 endpoint、客户端特定通道故障。它们不是当前用户机器的证据，不能声称升级到某版本必修复。

## 4. 本项目可以安全验证什么

依据 [curl 官方手册](https://curl.se/docs/manpage.html) 采用显式代理、HTTP/1.1 Upgrade、有限超时和 TLS 校验；依据 [RFC 6455](https://www.rfc-editor.org/rfc/rfc6455) 对随机 nonce 对应的 Accept 等字段进行校验。代理 CONNECT 的 200、普通 HTTPS 200、只有 101 状态都不能单独算有效握手。

匿名端点可以拒绝认证而不进入 Upgrade。401/403 并不能证明 WSS 可用或被封，404/405 也可能仅是路径/方法处理。因此未得到有效 101 时结论必须是“未验证”。即使验证 101，本工具不解析帧、不验证 ping/pong、业务流或持续连接，无法证明长连接稳定。

系统 DNS 有结果不能排除 Fake-IP 路由、上游 DNS、代理端解析或特定地址族问题。IPv4/IPv6 对照只覆盖实际受测的一段；连接本机 IPv4 代理无法推断代理到目标使用 IPv4。不能由此自动更改 DNS、关闭 IPv6或安装 CA。

## 5. 对当前症状的判断

用户确认：已进主界面，发送后重连，系统代理开启、TUN 未解决，DNS 有结果，7897 HTTPS 部分失败/超时。**网络稳定性或路径问题应优先验证，但认证、客户端和长连接问题仍未排除。** 尚无证据支持直接改 Codex transport、全局设置变量或替换 DNS。

本轮没有找到能在未知应用版本、未读认证/配置、且现有代理本身仍部分失败的情况下，直接安全自动化的稳定官方通用修复。因此只交付只读工具与待确认方案；收到本机结果后再选择修复，不安装或调用不明“修复器”。
