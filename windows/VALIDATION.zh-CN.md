# Windows 原生版 —— 验收清单

在真实 Windows 机器上逐项验证原生版的分步流程。下面每一段"期望输出"都直接摘自
实际实现，所以对不上就说明有问题，而不是期望写高了。

全程约 10 分钟（大部分时间在等港大的 MFA 提示）。

全程开**两个** PowerShell 窗口：一个跑启动器，另一个查看路由、日志和状态文件。

---

## 第 0 步 —— 前置条件

| 要求 | 检查方式 |
|---|---|
| Windows 10 1803+ / Windows 11，64 位 | `winver` |
| PowerShell 5.1 | `$PSVersionTable.PSVersion`（下限是 5.1） |
| 仓库 | `git clone https://github.com/jialiangZ/hkuvpn.git $HOME\hkuvpn` |
| OpenConnect + gost | `powershell -ExecutionPolicy Bypass -File $HOME\hkuvpn\windows\bin\get-tools.ps1` |

`get-tools.ps1` **必须以管理员身份运行** —— OpenConnect 安装程序要注册 Wintun
网络适配器。两份下载都做 SHA-256 校验：gost 对官方 go-gost checksums，OpenConnect
对官方 v9.21 **tag** 构建的固定哈希（tag 流水线的产物永久保留，而漂移的 `master`
产物一周后就过期）。OpenConnect 9.21 与 Docker 镜像内构建的版本一致，安装完成后安装
包会被删除。

已在 Windows 11（build 26300）+ PowerShell 5.1 上验证。

账号信息放在仓库之外：

```powershell
mkdir $HOME\.vpn -Force
copy $HOME\hkuvpn\windows\examples\hku.env.example $HOME\.vpn\hku.env
notepad $HOME\.vpn\hku.env          # 设置 HKU_USER=youruid@connect.hku.hk
Set-Content $HOME\.vpn\hku.pass '你的静态 Portal PIN'
```

`hku.pass` 里放的是**静态 Portal PIN**，不是每 30 秒变化的六位动态码。

---

## 第 1 步 —— 预检（`--check`）

不需要管理员权限。

```powershell
cd $HOME\hkuvpn\windows\bin
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 --check
echo $LASTEXITCODE     # 期望 0
```

期望输出：

```text
admin    : not elevated (connect self-elevates via UAC)
config   : ok (HKU_USER=youruid@connect.hku.hk)
pin file : ok (C:\Users\<你>\.vpn\hku.pass)
openconn.: ok (C:\Program Files\OpenConnect\openconnect.exe)
gost     : ok (C:\Users\<你>\hkuvpn\windows\tools\gost.exe)
script   : ok (etc\vpnc-script-win.js)
curl.exe : ok
ports    : 127.0.0.1:1080 and 1088 free
cert pin : not cached (fetched at connect)
autoroute: on (0 learned route(s) cached; external HKU resources are routed on demand)
result   : ready to connect (hkuvpn.ps1 or hkuvpn.ps1 -d)
```

某一行是红色时，报错信息本身就写了怎么修：

| 行 | 含义 |
|---|---|
| `config : HKU_USER missing or still the placeholder` | `hku.env` 还写着 `youruid@…` 占位值 |
| `openconn.: not found` | `get-tools.ps1` 没跑成功，或 `HKUVPN_OPENCONNECT` 路径不对 |
| `gost : not found` | `get-tools.ps1` 没下载 gost，或 `HKUVPN_GOST` 路径不对 |
| `ports : … in use` | 1080/1088 被别的代理占用 —— 改 `hku.env` 里的 `HKU_SOCKS_PORT` / `HKU_HTTP_PORT` |
| `result : NOT ready` | 失败项数量，退出码为 1 |

---

## 第 2 步 —— 连接

```powershell
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1
```

会弹 UAC 提示（启动器自提升 —— 建 Wintun 适配器和改路由需要管理员权限）。期望：

```text
Server: vpn2fa.hku.hk
Local proxies: SOCKS5=127.0.0.1:1080 HTTP=127.0.0.1:1088
started openconnect (pid 12345) and gost (pid 12346)
Portal PIN sent; waiting for the MFA prompt...
```

然后输入当前的六位动态验证码 —— 要输入**此刻** App 上显示的那一个，因为验证码只有约 30 秒有效期。若被网关拒绝，你会看到：

```text
The previous MFA code was rejected; enter the current one.
```

这不是移植的故障：输入当前有效的码即可继续。窗口保持前台连接，`Ctrl+C` 断开。

---

## 第 3 步 —— 路由脚本确实执行了（最关键的一项）

在**第二个**窗口：

```powershell
Get-Content $env:TEMP\hkuvpn\openconnect.log | Select-String 'connect done'
```

期望每次会话出现一行：

```text
2026/11/1 18:20:11 [vpnc] connect done: 0 v4 route(s), 0 v6 route(s), dns=[147.8.2.254 147.8.145.254]
```

`0 v4 route(s)` 是港大网关的正常表现：它是 full-tunnel 网关，不下发任何分流路由，
原生版因此改为按需路由（见"授权资源自动路由"一节）。DNS 服务器无论如何都会记录。

**没有**这一行，说明 vpnc 脚本压根没跑。检查 OpenConnect 命令行里有没有
`--script="…\windows\etc\vpnc-script-win.js"`，以及 `cscript.exe` 是否可用。

### 默认路由绝对不能变

```powershell
route print -4
```

期望：新增指向 Wintun 接口的校园网段条目，**而 `0.0.0.0/0` 默认路由仍然指向你的
物理网卡**。如果发现 `0.0.0.0/0` 被挪到了隧道上，请立刻停止并反馈 —— 这正是本版
要保护的性质。

### 落盘的状态

```powershell
Get-Content $env:TEMP\hkuvpn\vpnc-state.txt
```

期望：

```text
TIME=2026/11/1 18:20:11
TUNIDX=23
IP4=147.8.x.y
MASK=255.255.255.0
DNS=147.8.4.4 147.8.80.4
ROUTE=147.8.0.0/16
…
```

---

## 第 4 步 —— 校园 DNS（NRPT 规则）

```powershell
Get-DnsClientNrptRule | Format-List
```

期望：有一条 `Comment = hkuvpn` 的规则，`NameServers` 是 VPN 自带的 DNS，这样
`*.hku.hk` 名字会通过隧道解析。

没有规则时看标记：

```powershell
Get-Content $env:TEMP\hkuvpn\markers.log
```

`HKUVPN_NRPT_SKIPPED dns-not-routed` 是**正常**的 —— 表示 VPN 下发的 DNS 不在
推送网段内，加了规则也没用。`HKUVPN_NRPT_DISABLED` 表示 `hku.env` 里设了
`HKU_NRPT=0`。

---

## 第 5 步 —— 分层健康检查（`--status`）

```powershell
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 --status
echo $LASTEXITCODE
```

期望：

```text
process  : up
tunnel   : up (split routes active)
proxy    : ok (127.0.0.1:1080)
e2e      : ok (https://www.hku.hk -> HTTP 200 through the HKU tunnel)
```

退出码 `0`。各层是**按顺序**判定的，所以第一个失败的层就指明了排查方向：

| 退出码 | 层 | 常见原因 |
|---|---|---|
| 2 | `process : not running` | 隧道进程已退出 —— 看 `--logs` |
| 3 | `tunnel : down` | OpenConnect 还在认证，或会话失败 |
| 4 | `proxy : down` | gost 没在监听 —— 看 `%TEMP%\hkuvpn\gost.log` |
| 5 | `e2e : failed` | `www.hku.hk` 不在推送的分流网段内，某些网络下属预期 |

退出码 5 往往**不是 bug**：本版只路由服务器推送的网段，不在校园区段内的公网站点
本来就无法经隧道访问 —— 换一个确实托管在校内的主机来验证。

---

## 第 6 步 —— 代理可用

```powershell
curl.exe -x socks5h://127.0.0.1:1080 -I https://www.hku.hk/
curl.exe -x http://127.0.0.1:1088     -I https://www.hku.hk/
```

用 `socks5h`，让 DNS 也走代理解析。

---

## 第 7 步 —— 校外授权资源的自动路由

这是原生版补上与 Docker 版差距的关键功能。挑一个部署在校外网络的港大授权资源
（比如某个图书馆数据库）：

```powershell
curl.exe -x socks5h://127.0.0.1:1080 -I https://<授权库主机>/
```

**第一次**请求可能失败 —— 路由是从这次请求学到的。再发一次，第二次就通了。

确认学到了什么：

```powershell
Get-Content $env:TEMP\hkuvpn\markers.log | Select-String 'HKUVPN_ROUTE_ADDED'
Get-Content $env:USERPROFILE\.vpn\learned-routes.txt
route print -4 | Select-String '<学到的网段>'
```

期望：标记日志出现 `HKUVPN_ROUTE_ADDED <base>/24 <- <label>`；
`learned-routes.txt` 有对应的 `base/24|<epoch>|<host>` 行；`route print -4` 里能看到
该网段指向隧道接口。

学到的路由是**持久化**的，下次会话直接生效。想清空就删掉 `learned-routes.txt`。

---

## 第 8 步 —— 停止并确认没有残留

```powershell
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 --stop
```

然后确认主机是干净的：

```powershell
route print -4                      # 校园网段路由已消失；0.0.0.0/0 仍在物理网卡
Get-DnsClientNrptRule               # 没有 Comment = hkuvpn 的规则
Get-Process openconnect,gost -ErrorAction SilentlyContinue   # 无输出
```

除此之外不应有任何改动：没有 WSL、没有 Docker、没有服务、没有计划任务。本版创建
的文件只有这些：

| 路径 | 内容 | 能否删除 |
|---|---|---|
| `%TEMP%\hkuvpn\` | 日志、标记、pid 列表、状态文件 | 随时可删 |
| `%USERPROFILE%\.vpn\hku.env`、`hku.pass` | 你的凭据 | 保留（配好 NTFS ACL） |
| `%USERPROFILE%\.vpn\pin-hk.cache` | 证书指纹缓存 | 可删 |
| `%USERPROFILE%\.vpn\learned-routes.txt` | 学到的路由 | 可删 |

---

## 第 9 步 —— 后台模式 + `--mfa`（可选）

```powershell
# 窗口 1：后台启动，等待验证码
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 -d

# 窗口 2：送入当前验证码
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 --mfa 123456

# 窗口 2：确认
powershell -ExecutionPolicy Bypass -File .\hkuvpn.ps1 --status
```

`-d` 模式不会提示输入验证码，必须另行送入。工作进程最多等待 30 秒，超时后退出
（标记日志里是 `HKUVPN_EXITED`）。

---

## 反馈模板

如果某一步失败，把下面的内容贴回来：

```text
Windows 版本:       10.0.19045 / 11.x
PowerShell:         5.1.x
OpenConnect:        <`openconnect.exe --version` 的输出>
--check 结果:       <有红字就贴红字>
--status 结果:      <输出>   退出码: <n>
openconnect.log:    <'connect done' 附近的行，或最后几行报错>
markers.log:        <全文>
route print -4:     <0.0.0.0/0 那一行，以及所有校园网段条目>
```
