# hkuvpn — 原生 Windows 版

**直接在 Windows 上运行 HKU VPN** —— 无需 WSL、无需 Docker。本移植保留主项目的核心设计目标：默认路由和日常上网完全不受影响，只有你主动走本地代理的流量才进入校园网。

> **状态：已实地验证，但还年轻。** 所用组件均为官方构建（OpenConnect 官方 Windows 版、gost 官方发行包），并已在真实 HKU 账号 + Windows 11 + PowerShell 5.1 上跑通完整会话（连接、路由、授权资源路由、干净退出）。它仍比容器版新很多，建议保留 Docker/WSL 版本作为后备。差异详见[已知差异](#与-wsldocker-版的已知差异)。

## 拿到桌面 App

只想在 Windows 上用这个 VPN，不需要从本仓库拿任何东西——除了 App 本身。

1. 从 [Releases](https://github.com/jialiangZ/hkuvpn/releases) 下载
   **`HKUVPN-windows-<版本号>.zip`**。
2. 解压到任意位置，比如 `C:\hkuvpn`。
3. **以管理员身份运行一次** `bin\get-tools.ps1`。它会安装 OpenConnect
   （自带 Wintun 网卡）并下载 gost；两个下载都做固定的 SHA-256 校验。
4. 启动 `HKUVPN.exe`，填入 HKU 账号和 Portal PIN，点 Connect。

压缩包里有 `START-HERE.md`（英文）和 `START-HERE.zh-CN.md`（中文），
一步一步写清楚了。你输入的东西不会离开本机，App 的日志也只留在本地磁盘。

想自己从源码编译，见 [`mygo-app/README.zh-CN.md`](mygo-app/README.zh-CN.md)
—— 那需要在 Windows 上装 Go 1.27。

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

## 访问校园内网主机

这个部署的网关只下发一条分片路由（`10.64.192.0/20`，即隧道自己的网段），
`10.x` 里其它地址一律不进隧道；上面的自动学习又**明确拒绝 RFC1918** 私网地址。
所以像实验室服务器这样只在校内可达的主机，必须自己把网段写进去：

```ini
# %USERPROFILE%\.vpn\hku.env
HKU_EXTRA_ROUTES=10.128.0.0/16
```

几条能省时间的规则：

- **逗号分隔**，例如 `10.128.0.0/16,10.140.0.0/16`；
- 改完必须**重连**：路由是 vpnc 脚本在连接时加的（`HKUVPN_AUTOROUTE_ON` 标记、`route print -4` 可见）；
- **尽量窄**：写 `/8` 会把你自己的 Wi-Fi 内网段也罩进去；实验室一个 `/16` 就够，隧道自己的 `10.64.192.0/20` 本来就有路由；
- 这个值和 `shell\bootstrap.ps1` 写进 `hku.env` 的是同一个，换机器时可以跟账号一起配好。

配好之后直接连主机 —— `ssh <user>@<lab-host> -p <port>`、
`Test-NetConnection <lab-host> -Port <port>` —— 而不是走代理：
`HKU_EXTRA_ROUTES` 加的是系统路由，该主机在隧道的校园一侧。

## 环境要求

- Windows 10 1803+ / Windows 11，64 位（系统自带 `curl.exe`）
- PowerShell 5.1（系统自带）
- 管理员权限 —— 连接时 hkuvpn.ps1 会自动弹 UAC 提权（创建 wintun
  网卡和修改路由需要）。停止一个活跃会话**不需要** UAC：提权中的 worker
  会自己清理干净。
- 开通了 VPN 的 HKU 账号、**静态 Portal PIN**、**Microsoft Authenticator
  动态码**（与 Docker 版相同）

## 安装

```powershell
cd $HOME\hkuvpn\windows\bin
powershell -ExecutionPolicy Bypass -File .\get-tools.ps1
```

该脚本会下载 gost 和 OpenConnect 安装包，**两者都做 SHA-256 固定校验**，并在已提权时自动静默安装。gost 取官方 go-gost 发行包；OpenConnect 取官方 GitLab CI 的 **v9.21 tag** 构建（tag 流水线的产物永久保留，而漂移的 `master` 产物会过期）—— 与 Docker 镜像内的 OpenConnect 版本一致。安装完成后安装包会被删除。

最快：`shell\bootstrap.ps1` 会问账号和 Portal PIN、把两个文件写好，还能顺带记下
你要用的校园网段（见上一节）。已有的文件不加 `-Force` 不会被覆盖。

```powershell
powershell -ExecutionPolicy Bypass -File ..\shell\bootstrap.ps1
```

或者手工来 —— 文件路径和格式与 Docker 版一致：

```powershell
mkdir $HOME\.vpn
copy $HOME\hkuvpn\windows\examples\hku.env.example $HOME\.vpn\hku.env
notepad $HOME\.vpn\hku.env          # 填写 HKU_USER
Set-Content $HOME\.vpn\hku.pass '你的静态Portal-PIN'
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 --check
```

可选：把 `shell` 目录加进用户 PATH（只需一次），这样 `hkuvpn` 在 cmd、PowerShell、
Windows Terminal 里都是真命令 —— 不再需要在 `$PROFILE` 里定义函数去覆盖它，也不需要管理员权限：

```powershell
powershell -ExecutionPolicy Bypass -File ..\shell\install-path.ps1
```

之后裸 `hkuvpn` 走 `-t`：MFA 就在当前窗口输入、不开第二个控制台，并且补上 `-t`
自己做不了的一件事 —— 如果在隧道建立**之前**关掉窗口（或 Ctrl+C），`hkuvpn-watchdog.ps1`
会发现并让隐藏的 worker 停下，而不是让它一直等验证码；UAC 弹窗还没点、窗口就关了的情况
也在覆盖之内（比会话更新的停止标记会被当成停止请求而不是残留）。已连接的会话不会被碰，
所以连上之后关窗照旧不影响 VPN。`install-path.ps1 -Remove` 可撤销这条 PATH。

`shell` 与 `bin` 分开是故意的：PowerShell 在基名相同时会优先执行 `.ps1` 而不是
`.cmd`，若把 `hkuvpn.cmd` 放在 `hkuvpn.ps1` 旁边，裸命令在 PowerShell 里会变成
"智能模式"、在 cmd 里却是 `-t`。分开之后两边语义一致。

## 日常命令

```powershell
hkuvpn              # 智能连接：提示输入 MFA 动态码，等待隧道建立
                    #（PATH 上的裸 `hkuvpn` 走的是 -t，见「安装」）
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

- **桌面 App**（MyGo 原生 UI，`windows\mygo-app`）：`HKUVPN.exe`，用 MyGo 官方组件搭的紧凑窗口 —— 状态卡片（状态、隧道地址、时长、代理、路由）、带标签的 HKU 账号与 Portal PIN 输入框（编辑后自动保存）、单一主按钮 Connect / Cancel / Disconnect、View log 日志面板（级别标签 + 分级筛选 + 搜索 + 复制 + 导出）、Diagnostics 诊断面板（连接前的自检 + 本地代理连通性与出口地址）、Routes 路由面板（查看/增删自动学习到的路由）、Settings 设置面板（`hku.env` 里的高级选项、开机自启、断线自动重连）与 MFA 对话框（**必经关口**：输入 6 位码才继续，关掉弹窗＝取消这次连接，没有"待会儿再输"），关闭窗口收进托盘；几个面板入口是窗口下方的一排图标（悬停有提示），每个面板都开在自己的窗口里（日志才有地方显示）。所有窗口大小固定：不能缩放，最大化按钮是灰掉的。纯 Go 构建（`GOOS=windows go build`，无 cgo、无 WebView），见 `windows\mygo-app\build.sh`；exe 以 GUI 方式编译（`-H=windowsgui`），启动时不会弹出终端窗口，App 自身日志写入 `%LOCALAPPDATA%\HKUVPN\app.log`（不是 `%TEMP%`：这份日志是留着事后查的，临时目录会被系统随时清掉），按天或超过 1 MB 滚动，保留 7 天。托盘图标为四状态盾牌（灰/绿/琥珀/红），由 `windows\mygo-app\assets\tray-icon.svg` 生成。断开免 UAC，退出 App 不影响会话。
- **智能模式**（默认）：整个会话挂在当前控制台，关窗/Ctrl+C 即断开，适合双击图标使用；
- **`-t` 终端模式**：隧道跑在隐藏的提权 worker 里，MFA 直接在你的终端输入（投递空码或超时会自动停掉 worker）。连接后**关闭终端不影响 VPN**，适合日常从终端启动；如果窗口在连上**之前**就关掉或被 Ctrl+C 打断，从裸命令启动时会有 `hkuvpn-connect.ps1` 拉起的 `hkuvpn-watchdog.ps1` 兜底：它看到控制台进程消失、且还没出现 `HKUVPN_CONNECTED`，就写下 worker 的停止标记；即使 UAC 弹窗拖延了 worker 的启动，比会话更新的停止标记也会被当作停止请求执行。已连接的会话不动，所以同一条命令连上之后关窗仍然安全；
- **`-d` 后台模式**：无交互启动，配合 `--mfa` 投递，适合脚本。

**回归脚本**（`windows\tests\session-flow.ps1`）：把 worker 和 App 完整跑一遍会话
生命周期 —— 动态码弹窗是关口（关掉即取消）、连接、断开 —— 并检查不变量：拆除标记、没有强杀、
没有残留的 `gost`/`openconnect`、App 回到"未连接"。需要人参与的只有 UAC 弹窗和动态码，
所以要在 PowerShell 窗口里跑（动态码要手输）；`-SkipLive` 可以跳过需要动态码的那一项。
孤儿守护另有独立测试 `windows\tests\watchdog.ps1`：四个用例，不需要 UAC，也不需要真连 VPN。

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
| UAC | Windows 侧不需要 | 每次连接弹一次 UAC；断开活跃会话不需要 |

## 故障排查

- **一直不见 `HKUVPN_MFA_RESPONSE_REQUIRED`** —— 运行 `hkuvpn --logs`；
  证书/TLS 错误通常意味着 pinned 证书更换：删除
  `%USERPROFILE%\.vpn\pin-hk.cache` 后重连。（Windows 本身基本不会出现
  WSL 那种时钟漂移问题。）
- **隧道已通，但非校园站点 e2e 失败** —— 分流模式下只有下发网段（和附加、自动
  学习的路由）会经过 VPN。新校外资源的第一次请求会触发学习（看
  `%TEMP%\hkuvpn\markers.log` 里的 `HKUVPN_ROUTE_ADDED`），重试一次即走隧道。
  `route print -4` 可查看全部已装路由。
- **传大文件卡死、交互式会话挂起，但短命令正常** —— UDP 数据通道（DTLS）在你
  的线路上被限速了。跨境链路对 UDP（尤其 UDP/443）的待遇往往远差于 TCP；可以用
  `ping -n 100 <校园主机>` 经隧道测一下丢包。DTLS 默认关闭正是为此——除非你的
  线路很干净，否则保持默认。UDP 质量好的网络（如在香港境内）可在
  `%USERPROFILE%\.vpn\hku.env` 设置 `HKU_DTLS=1`：往返延迟降到约四分之一
  （实测 44 ms vs 192 ms），且 worker 会把隧道 MTU 压到 DTLS 实际承载值，
  大传输不会卡死。
- **会话冻结（无 keepalive）** —— 同因同解：保持默认 TCP 通道即可
  （不写 `HKU_DTLS` 行，或写 `HKU_DTLS=0`）。
- **异常退出后路由残留** —— 运行 `hkuvpn --stop`（会重放 disconnect 脚本
  并删除 NRPT 规则），或用 `route print` 检查。若 gost 孤儿进程占着
  1080/1088，下次连接会自动回收（`HKUVPN_ORPHAN_GOST_REAPED`）。
- **`--mfa` 提示没有 worker** —— 后台 worker 提前退出了；直接运行
  `hkuvpn` 观察输出。

## 安全说明

- Portal PIN 从 `%USERPROFILE%\.vpn\hku.pass` 读取，经 stdin 管道投递给
  OpenConnect，绝不出现在命令行。
- 运行状态（日志、标记、PID 列表）位于 `%TEMP%\hkuvpn`；**日志保留策略**：每次连接一份
  （`openconnect.log`，旧的滚动为 `.1 .2 .3`，超过 2 MB 也滚），`gost.log` 同样 2 MB × 3 代，
  App 自身日志在 `%LOCALAPPDATA%\HKUVPN\app.log`，按天滚动保留 7 天。
- MFA 动态码文件只在 `--mfa` 投递到 worker 消费之间的几秒内存在，随后
  立即删除。
- 与容器版不同，OpenConnect 外面没有沙箱；信任模型等同于信任官方二进
  制文件本身，一如你信任 Docker 镜像。
