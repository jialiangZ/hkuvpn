# hkuvpn — 原生 Windows 版

**直接在 Windows 上运行 HKU VPN** —— 无需 WSL、无需 Docker。本移植保留主项目的核心设计目标：默认路由和日常上网完全不受影响，只有你主动走本地代理的流量才进入校园网。

> **状态：已实地验证，但还年轻。** 所用组件均为官方构建（OpenConnect 官方 Windows 版、gost 官方发行包），并已在真实 HKU 账号 + Windows 11 + PowerShell 5.1 上跑通完整会话（连接、路由、授权资源路由、干净退出）。它仍比容器版新很多，建议保留 Docker/WSL 版本作为后备。差异详见[已知差异](#与-wsldocker-版的已知差异)。

第一次在本移植上动手？先按[验收清单](VALIDATION.zh-CN.md)走一遍 —— 从 `--check`
到"主机上没有任何残留"，每一步都写明了期望输出。

## 工作原理

```
应用程序 ──► 127.0.0.1:1080 (SOCKS5) / :1088 (HTTP) ──► gost
                                                        │
      Windows 路由表：按需路由的目标 ─────────────────────┴─► tun (wintun) ──► HKU
      其他所有流量 ────────────────────────────────────────► 物理网卡（正常上网）
```

| 职责 | 组件 |
|---|---|
| VPN 客户端 | `openconnect.exe`（官方 Windows CLI 构建，Wintun 虚拟网卡） |
| 认证自动化 | `hkuvpn.ps1` 应答 Portal PIN 提示、循环处理 MFA 表单 |
| 代理监听 | `gost.exe`（与容器镜像内同源的官方二进制） |
| 路由 | `etc\vpnc-script-win.js` —— 只做分流（split-tunnel）的定制脚本 |

与 OpenConnect 自带脚本的关键区别：我们的脚本**绝不通过隧道安装默认路由**，只添加 VPN 服务器下发的网段（`CISCO_SPLIT_INC_*`）加上你配置的 `HKU_EXTRA_ROUTES`，其余流量照常走物理网卡。

港大网关是**不下发任何分流路由的 full-tunnel 网关** —— 日志里 `connect done: 0 v4 route(s)` 是正常现象而非故障。网关会把公网目标经隧道转发，所以原生版改为**按需路由**（见下）。校园内部域名通过 NRPT 规则用 VPN 自己的 DNS 解析 `*.hku.hk`；**只有这些 DNS 经隧道确实可达时才会加规则**。港大这边不可达，因此会主动跳过（`HKUVPN_NRPT_SKIPPED dns-not-routed`）—— 指向不可达解析器的规则只会让域名查询变黑洞。

## 授权资源自动路由

Windows 没有按进程分流的能力，原生版用**自动学习路由**（`HKU_AUTO_ROUTES=1`，默认开启）补齐与 Docker 版的差距：

1. gost 以 debug 模式运行，会在**拨号之前**记录代理要访问的目标 —— 所以连不上的目标同样会被学到（这正是"必须走校园出口才能访问"的授权资源的典型情况）。
2. 当代理目标**不在**服务器下发的网段内（如托管在校外的图书馆数据库），自动把它的前缀（默认 `/24`）路由进隧道。
3. 学习结果保存在 `%USERPROFILE%\.vpn\learned-routes.txt`，跨会话复用（TTL 14 天、上限 512 条），下次连接时自动重装。

实际效果一句话：**只要走了本地代理，就自动经 HKU 出网**。全新的校外资源第一次请求会触发学习（刷新一次页面即可），想连第一次都直达就把域名加进 `HKU_PROXY_DOMAINS` 预置。私网、CGNAT、组播和规则客户端 fake-IP（`198.18.0.0/15`）地址永远不会被学习。可用 `hkuvpn.ps1 --check`、`%TEMP%\hkuvpn\markers.log` 里的 `HKUVPN_ROUTE_ADDED` 标记或 `route print -4` 观察；删除 `learned-routes.txt` 即可清空学习记录。

需要知道的副作用：学习到的 `/24` 对整个系统生效，未走代理的程序访问同一网段也会从 HKU 出网（通常无关紧要——那个网段本来就属于授权资源）。

## 环境要求

- Windows 10 1803+ / Windows 11，64 位（系统自带 `curl.exe`）
- PowerShell 5.1（系统自带）
- 管理员权限 —— 连接/停止时 hkuvpn.ps1 会自动弹 UAC 提权（创建 wintun
  网卡和修改路由需要）
- 开通了 VPN 的 HKU 账号、**静态 Portal PIN**、**Microsoft Authenticator
  动态码**（与 Docker 版相同）

## 安装

```powershell
cd $HOME\hkuvpn\windows\bin
powershell -ExecutionPolicy Bypass -File .\get-tools.ps1
```

该脚本会下载 gost 和 OpenConnect 安装包，**两者都做 SHA-256 固定校验**，并在已提权时自动静默安装。gost 取官方 go-gost 发行包；OpenConnect 取官方 GitLab CI 的 **v9.21 tag** 构建（tag 流水线的产物永久保留，而漂移的 `master` 产物会过期）—— 与 Docker 镜像内的 OpenConnect 版本一致。安装完成后安装包会被删除。

然后配置 —— 文件路径和格式与 Docker 版一致：

```powershell
mkdir $HOME\.vpn
copy $HOME\hkuvpn\windows\examples\hku.env.example $HOME\.vpn\hku.env
notepad $HOME\.vpn\hku.env          # 填写 HKU_USER
Set-Content $HOME\.vpn\hku.pass '你的静态Portal-PIN'
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 --check
```

可选：把简短命令加进 PowerShell 配置文件（`$PROFILE`）：

```powershell
function hkuvpn { & "$HOME\hkuvpn\windows\bin\hkuvpn.ps1" @args }
```

## 日常命令

```powershell
hkuvpn              # 智能连接：提示输入 MFA 动态码，等待隧道建立
hkuvpn              # 已连接时再次运行：报告状态（提权窗口停 5 秒后自动关闭）
hkuvpn --check      # 预检（退出码 0 = 就绪）
hkuvpn -f           # 前台连接，回显 OpenConnect 原始日志
hkuvpn -t           # 终端连接：隐藏提权 worker，MFA 在当前终端输入，无第二窗口
hkuvpn -d           # 后台连接（等待 MFA 就绪后返回）
hkuvpn --mfa 123456 # 向后台 worker 投递动态码
hkuvpn --status     # 分层健康检查（退出码 0/2/3/4/5）
hkuvpn --logs       # 跟踪 OpenConnect 日志
hkuvpn --stop       # 停止（活跃 worker 自清理，免 UAC；死会话强杀才需提权）
```

**提示后立刻输入动态码。** Authenticator 的码只有约 30 秒有效期，过期后网关会拒绝。若被拒绝，启动器会明确提示 `The previous MFA code was rejected; enter the current one` 并重新询问 —— 此时输入**当前显示**的码即可。`-d` 后台模式同理：投递给 worker 的必须是**当下**有效的码，而不是提前抄下来的旧码。

三种长会话模式按场景选：

- **桌面 App**（RmlUi 前端，`windows\app`）：`HKUVPN.exe`，紧凑的浅色窗口 —— 状态卡片（状态、隧道地址、时长、代理、路由）、单一主按钮 Connect / Cancel / Disconnect、View log 日志面板、账号对话框（HKU 账号 + Portal PIN）与 MFA 提示框，关闭窗口收进托盘。界面由 `ui/*.rml`、`ui/*.rcss` 与静态链接的 RmlUi 组成，见 `windows\app\build.sh`（首次需 `./build.sh deps` 构建 RmlUi/FreeType）。断开免 UAC，退出 App 不影响会话。
- **智能模式**（默认）：整个会话挂在当前控制台，关窗/Ctrl+C 即断开，适合双击图标使用；
- **`-t` 终端模式**：隧道跑在隐藏的提权 worker 里，MFA 直接在你的终端输入（投递空码或超时会自动停掉 worker）。连接后**关闭终端不影响 VPN**，适合日常从终端启动；
- **`-d` 后台模式**：无交互启动，配合 `--mfa` 投递，适合脚本。

另外两个自愈机制：连接入口会自动回收上个崩溃会话遗留的 gost（否则它占着 1080/1088 会让之后每次连接都失败，标记 `HKUVPN_ORPHAN_GOST_REAPED` 留痕）；任何模式的异常退出都会把错误写进 markers（`HKUVPN_EXITED error=...`），窗口闪退也不会丢失诊断线索。

代理使用方式与 Docker 版完全一致：SOCKS5 `127.0.0.1:1080`、HTTP
`127.0.0.1:1088`，Clash Verge / Surge 照主指南配置，同样注意"VPN 服务器
本身必须直连"的规则。

## 与 WSL/Docker 版的已知差异

| 主题 | Docker 版 | 原生版 |
|---|---|---|
| 哪些流量走 HKU | 代理的**全部**流量（容器默认路由 = tun） | 只有你交给代理的流量，且**按需路由**：自动学习到的路由（`HKU_AUTO_ROUTES`）+ `HKU_EXTRA_ROUTES`。网关不下发分流路由，没有别的可路由 |
| 流量从哪里出网 | 容器发出的流量都走校园出口 | 代理的目标经按需学到的路由走校园出口 |
| 校外托管的 HKU 授权资源（图书馆数据库等） | 经代理可直接用 | 自动学习，**首次尝试失败也能学到**（目标在拨号瞬间就被记录）；可用 `HKU_PROXY_DOMAINS` 预置 |
| `socks5h` 域名解析 | 容器内经隧道解析 | 由代理用主机解析器解析；`*.hku.hk` 走 NRPT 规则 —— 但只有网关的 DNS 经隧道可达时才加（港大这边不可达，故主动跳过） |
| 隔离性 | 容器沙箱、剥离 capabilities | 以提权用户身份直接运行 |
| PIN 文件安全 | WSL 内 chmod 600 | 位于 `%USERPROFILE%\.vpn`；需要时用 NTFS ACL 加固 |
| 前置条件 | Docker 运行时（WSL） | 只要装好上述工具；不需要 WSL |
| UAC | Windows 侧不需要 | 每次连接/停止弹一次 UAC |

## 故障排查

- **一直不见 `HKUVPN_MFA_RESPONSE_REQUIRED`** —— 运行 `hkuvpn --logs`；
  证书/TLS 错误通常意味着 pinned 证书更换：删除
  `%USERPROFILE%\.vpn\pin-hk.cache` 后重连。（Windows 本身基本不会出现
  WSL 那种时钟漂移问题。）
- **隧道已通，但非校园站点 e2e 失败** —— 分流模式下只有下发网段（和附加、自动
  学习的路由）会经过 VPN。新校外资源的第一次请求会触发学习（看
  `%TEMP%\hkuvpn\markers.log` 里的 `HKUVPN_ROUTE_ADDED`），重试一次即走隧道。
  `route print -4` 可查看全部已装路由。
- **会话冻结（无 keepalive）** —— 在 `%USERPROFILE%\.vpn\hku.env` 设置
  `HKU_DTLS=0`，与 Docker 版相同。
- **异常退出后路由残留** —— 运行 `hkuvpn --stop`（会重放 disconnect 脚本
  并删除 NRPT 规则），或用 `route print` 检查。若 gost 孤儿进程占着
  1080/1088，下次连接会自动回收（`HKUVPN_ORPHAN_GOST_REAPED`）。
- **`--mfa` 提示没有 worker** —— 后台 worker 提前退出了；直接运行
  `hkuvpn` 观察输出。

## 安全说明

- Portal PIN 从 `%USERPROFILE%\.vpn\hku.pass` 读取，经 stdin 管道投递给
  OpenConnect，绝不出现在命令行。
- 运行状态（日志、标记、PID 列表）位于 `%TEMP%\hkuvpn`。
- MFA 动态码文件只在 `--mfa` 投递到 worker 消费之间的几秒内存在，随后
  立即删除。
- 与容器版不同，OpenConnect 外面没有沙箱；信任模型等同于信任官方二进
  制文件本身，一如你信任 Docker 镜像。
