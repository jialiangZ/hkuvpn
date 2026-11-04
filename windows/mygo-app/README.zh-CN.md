# HKU VPN —— MyGo 桌面 App

[English](README.md)

港大校园 VPN 的原生界面客户端，用 [MyGo](https://github.com/egoist/mygo)
写成（纯 Go，Windows 上用 Direct3D 11 绘制，无 WebView）。
它驱动的是和 PowerShell 前端同一个提权工作进程：
`windows/bin/hkuvpn.ps1 --Worker` / `--stop`，协议文件在 `%TEMP%\hkuvpn`
（markers.log、hb.log、pids.txt、vpnc-state.txt、response.txt、stop.flag）。

**只想用、不想编译？** 去
[Releases](https://github.com/jialiangZ/hkuvpn/releases) 下载
`HKUVPN-windows-*.zip`，里面带一份 [`START-HERE.md`](START-HERE.md)
（中文版 [`START-HERE.zh-CN.md`](START-HERE.zh-CN.md)）。

## 窗口

每个窗口一个尺寸，不能缩放：这个 App 要显示的东西不多，
不能变大的窗口里就不会有空的地方（窗口选项里的 `DisableResize`
和 `DisableMaximize`）。

标题栏是系统自己的。Windows 11 即使窗口不能最大化也照样画最大化按钮，
所以它显示为灰色。

四个面板（日志、诊断、路由、设置）各自开在自己的窗口里：
主窗口很小，日志需要更多地方。排版用主题自带的间距（`t.Space(n)`），
和官方控件保持一致。

## 构建

    ./build.sh          # GOOS=windows go build -> publish/HKUVPN.exe

只需要 Go 1.27+，没有 C 工具链，也没有前端构建。

构建带 `-H=windowsgui`（以及 `mygo.production=1`）：exe 是 GUI 程序，
Windows 不会给它挂控制台，App 旁边不会多出一个终端窗口。
`go tool mygo build` 自己就带这个标志；`go tool mygo dev` 是例外 ——
开发版保留控制台，用来输出检查器信息。

## 日志

App 没有控制台，所以它自己的诊断写到 `%LOCALAPPDATA%\HKUVPN\app.log`
（启动失败还会弹一个消息框）。这是个持久位置，不是 `%TEMP%`：
这份日志是留着事后查的，而 Windows 会按自己的节奏清理临时目录。
跨天或超过 1 MB 就滚动，保留 7 天。

VPN 会话日志是另一个文件 `%TEMP%\hkuvpn\openconnect.log`，
在 Connection log 窗口里显示。工作进程每次连接尝试写一份新的，
所以两次运行不会混在一起；超过 2 MB 会滚动，保留三代。

## 开发

    go tool mygo dev    # 热重载
    go test             # 不用开窗口就能跑的测试

## App 做什么

- **会话**：Connect（UAC）→ 动态码对话框（这是个关口：输入码才继续，
  关掉它就是放弃这次连接）→ 隧道建好，状态卡上显示隧道地址、
  已连接时长、代理地址和学到的路由。连接中点 Cancel 会盯着工作进程
  直到它真的退出；Disconnect 不需要 UAC。关闭窗口只是收进托盘，
  退出 App 也不会掐掉会话。
- **诊断**：工作进程需要的东西（账号、PIN、工具、端口、证书指纹），
  以及对本地 SOCKS5 / HTTP 代理的连通性测试，含流量出口地址。
- **路由**：学到的路由（哪些流量走隧道），可以手动增删。
- **设置**：工作进程从 `hku.env` 读的高级选项（服务器地址、端口、DTLS、
  自动路由、DNS 规则、代理域名），以及 App 自己的偏好（开机自启、
  断线重连、启动即连接）。
- **日志**：会话日志，带级别标签、级别筛选、搜索框、复制和导出。

面板在窗口下方排成一排图标（`assets/ui/*.svg`，Lucide 风格的线条，
取文字颜色，所以会跟着主题走）。每个图标都有悬停提示。

App 自己的状态（偏好和本次会话的开始时间）在
`%USERPROFILE%\.vpn\app-state.json`。

运行时 App 会把当前状态写到 `%TEMP%\hkuvpn\app-status.txt`
（状态、worker、心跳、待输入的码、VPN 地址）。回归脚本读的就是它，
它也回答了"不打开窗口，App 觉得自己在干什么"。

## 托盘图标

`assets/tray-{gray,green,amber,red}.png`（64px，内嵌）表示连接状态，
由 MyGo 缩放到任务栏尺寸。它们用 `python3 make-tray-icons.py`
从 `assets/tray-icon.svg` 渲染 —— 改完 SVG 要重跑一次。

App 窗口本身刻意不放任何图标。
