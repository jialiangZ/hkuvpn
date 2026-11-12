# HKU VPN for Windows —— 从这里开始

你需要：

- **Windows 10 1803+ 或 Windows 11**，64 位
- 一个**开通了 VPN 的 HKU 账号**
- 你的**静态 Portal PIN**（港大门户里那个固定密码，不是动态码）
- 手机上的 **Microsoft Authenticator**（用来取 6 位动态码）

## 1. 解压

把 `HKUVPN-windows-<版本号>.zip` 解压到任意位置，比如 `C:\hkuvpn`。
解压后应该是这样：

```
HKUVPN.exe               桌面 App
bin\hkuvpn.ps1           App 驱动的工作进程
bin\get-tools.ps1        下载两个依赖（第 2 步）
shell\hkuvpn.cmd         在终端里使用的单字命令
shell\hkuvpn-connect.ps1 裸命令的流程与孤儿守护
shell\hkuvpn-watchdog.ps1
shell\bootstrap.ps1      写入账号与 PIN 配置（可选）
shell\install-path.ps1   把 shell 加进 PATH（可选）
etc\vpnc-script-win.js   路由脚本
examples\hku.env.example 配置模板
START-HERE.zh-CN.md      本文件
```

## 2. 安装两个依赖（只需一次）

在这个文件夹里打开 PowerShell，运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\bin\get-tools.ps1
```

UAC 弹窗请点允许。它会安装 **OpenConnect**（自带 Wintun 虚拟网卡），
并下载 **gost**（本地代理）。两个下载都会用固定的 SHA-256 校验；
哈希对不上就不会安装。

## 3. 启动 App

```powershell
.\HKUVPN.exe
```

窗口里是当前状态、两个输入框和一个按钮。

1. 填 **HKU account**（`youruid@connect.hku.hk`）和 **Portal PIN**。
   边打边存 —— 没有保存按钮，也不会发到任何地方。
2. 点 **Connect**，会弹 UAC，点允许。
3. 弹出 **Verification code** 时，输入 Authenticator 上的 6 位数字并回车。
   动态码只有约 30 秒有效期，请输入**此刻显示**的那个。
4. 隧道大约半分钟后建好，状态卡上会显示隧道地址和已连接时长。

代理在 `127.0.0.1:1080`（SOCKS5）和 `127.0.0.1:1088`（HTTP）。
把浏览器、SSH 或规则客户端指过去就行。

### 更想用命令行？

```powershell
powershell -ExecutionPolicy Bypass -File .\shell\bootstrap.ps1      # 账号、PIN、校园网段
powershell -ExecutionPolicy Bypass -File .\shell\install-path.ps1   # 只需一次，之后开新终端
hkuvpn
```

第一条写 `%USERPROFILE%\.vpn\hku.env` 和 `hku.pass`（两项都会问你，已有文件不加
`-Force` 不会覆盖）。第二条把 `shell` 写进用户 PATH（只需一次，不需要管理员权限）。
之后裸 `hkuvpn` 会在当前窗口要动态码、不开第二个控制台；连上之后关掉窗口，隧道照旧。
如果在连上之前就关窗，守护脚本会让 worker 停下，不会留下一个傻等验证码的进程。
`hkuvpn --status`、`--stop`、`--logs` 在任何终端里都能用。

如果这台机器要访问实验室内网这类校园专用主机，在 `bootstrap.ps1` 问网段时填上
（例如 `10.128.0.0/16`）：那正是 `HKU_EXTRA_ROUTES`，没有它 `10.x` 根本不通。

## 4. 用完之后

点 **Disconnect** —— 这次不用 UAC。关闭窗口只是把 App 收到托盘，
隧道照常运行；托盘图标也是回到窗口的入口。右键托盘图标选 **Exit**
才是退出 App（隧道会一直留到你断开为止）。

## 出问题了

- **Diagnostics**（窗口下方第二个图标）会检查 App 需要的东西，并测试本地代理。
- **Settings**（最后一个图标）里是高级选项，还有"开机自启"的开关。
- App 自身的日志在 `%LOCALAPPDATA%\HKUVPN\app.log`；
  会话日志在 `%TEMP%\hkuvpn\openconnect.log`。

欢迎到 <https://github.com/jialiangZ/hkuvpn/issues> 反馈 —— 那个表单会
问你要预检输出和日志片段，附上它们问题就能修。
