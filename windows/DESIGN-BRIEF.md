# HKU VPN 桌面端 · 设计说明（交付设计师）

> 用途：这是实现方对**当前可用版本**的完整拆解。设计师可以据此重做视觉，不必先读代码。
> 交付目标：一套现代、简洁、易读的浅色界面；保持本文列出的信息与操作不变。
>
> 实现是 **MyGo（Go 原生 UI）**：界面由官方组件（Form / Field / TextInput /
> Button / PrimaryButton / Modal / List / SearchField / Segmented / Toast / Tray）
> 搭建，主题沿用官方主题，只把强调色换成 HKU 深绿。阴影、渐变、模糊、SVG 图标
> 都可以落地。

---

## 1. 一句话定位

香港大学（HKU）校园 VPN 的 Windows 桌面客户端。用户输入 HKU 账号与 Portal PIN，
点击连接 → 通过 UAC 提权启动后台工作进程 → 输入 Microsoft Authenticator 的 6 位动态码 →
建立到 `vpn2fa.hku.hk` 的分流隧道；本地提供 SOCKS5 / HTTP 代理。关闭窗口不中断 VPN。

界面语言：**全英文**（文案见第 8 节，请沿用，不要翻译成中文）。

---

## 2. 画布与框架

| 项目 | 当前值 | 说明 |
|---|---|---|
| 主窗口尺寸 | 452 × 376（逻辑像素，**客户区**） | 固定尺寸，不可缩放、不可最大化；`UseContentSize` 表示这是客户区，标题栏另算 |
| 面板窗口尺寸 | 日志 640×460 · 诊断 480×460 · 路由 480×420 · 设置 480×660 | 同样是固定尺寸的客户区 |
| 标题栏 | 标准 Windows 标题栏 | 仅显示文字 “HKU VPN”，**无任何图标**（应用图标是一张全透明 PNG，让标题栏和任务栏按钮留白） |
| 背景 / 卡片 | 官方主题的 Surface / 背景色 | 状态卡是一张有圆角和 1px 边框的浅色卡片 |
| 圆角 | 状态卡 10 · 按钮官方值 · 输入框官方值 | 卡片圆角是自定义的，其余沿用官方主题 |
| 间距 | 官方主题的 `t.Space(n)`（n = 2/3/4） | 全部间距走主题 token，官方控件与自定义排版不会走样 |
| 强调色 | `#0B6B45`（hover `#0A5C3C`，pressed `#084B31`） | 只改主题的 Accent，其余颜色一个不动 |

设计稿请按 **100% 缩放**出图（逻辑像素 = CSS px）；小尺寸托盘图标另见第 7 节。

---

## 3. 主界面解剖（自上而下）

主窗口只有一张卡片、一个表单、一个按钮和一排图标，没有页头。

```
┌────────────────────────────────────────────┐
│  ┌──────────────────────────────────────┐  │
│  │ ● Connected                00:12:34  │  │  ← ① 状态卡
│  │ VPN address  10.64.199.140           │  │
│  │ Proxy        socks5://…·http://…      │  │
│  │ Routes       3 learned routes · …    │  │
│  └──────────────────────────────────────┘  │
│                                            │
│  HKU account   [ u3015850@connect.hku.hk ] │  ← ② 凭证表单
│  Portal PIN    [ ••••••••••••••         ] │  │
│                                            │
│  ┌────────────────── Connect ───────────┐ │  ← ③ 主操作
│  └──────────────────────────────────────┘ │
│                                            │
│                        [📄][✚][⇄][⚙]       │  ← ④ 面板入口（一排图标）
└────────────────────────────────────────────┘
```

| # | 区块 | 作用 |
|---|---|---|
| ① | 状态卡 | 一眼看清"现在是什么状态、隧道地址、代理、路由" |
| ② | 凭证表单 | 常驻的 HKU 账号与 Portal PIN 输入，编辑后自动保存 |
| ③ | 主操作 | 唯一的强按钮，随状态变形：Connect / Cancel / Disconnect |
| ④ | 面板入口 | 四个图标按钮（日志 / 诊断 / 路由 / 设置），各自开自己的窗口 |

> **没有页头、没有副标题、没有单独的账号卡、没有底部提示行。** 早期版本有
> "HKU Portal VPN · vpn2fa.hku.hk" 的页头和 "Account" 卡片标题，现已合并进状态卡与表单。

---

## 4. 组件详表

### ① 状态卡（浅色卡片，圆角 10，1px 边框）

| 元素 | 内容 | 样式现状 |
|---|---|---|
| 状态点 | 10 × 10 圆点（圆角 5） | 颜色 = 状态色，见第 5 节 |
| 状态文字 | `Disconnected` / `Reconnecting` / `Connecting` / `Connected` / `Disconnecting` / `Cancelling` / `Worker unresponsive` | 默认字号，Bold |
| 副状态 | 连接中时的 `Waiting for sign-in` 等短句 | 与状态文字同行，次级文字色 |
| 计时 | `--:--:--` 或 `00:12:34` | 右对齐，等宽字体，次级文字色 |
| 明细行 ×3 | `VPN address` · `Proxy` · `Routes` | 标签固定宽 92（次级色），值占满剩余宽度 |

**明细行的取值**

| 行 | 未连接 | 已连接 |
|---|---|---|
| `VPN address` | `—` | 隧道地址（适配器 IP，不是公网 IP） |
| `Proxy` | `socks5://127.0.0.1:1080 · http://127.0.0.1:1088` | 同左（端口随设置面板变化） |
| `Routes` | `—` | `3 learned routes · heartbeat OK`（心跳过期时 `heartbeat stale`） |

### ② 凭证表单（`ui.Form`，标签在控件左边）

| 元素 | 内容 |
|---|---|
| 字段 1 标签 | `HKU account` |
| 字段 1 占位 | `u1234567@connect.hku.hk` |
| 字段 2 标签 | `Portal PIN` |
| 字段 2 占位 | `Portal password`（以圆点掩码显示） |
| 输入框 | 官方 `TextInput`；聚焦时边框变品牌色 |

> 行为：**编辑后自动保存**（无保存按钮，停止输入约 0.7 秒后写盘）。
> 保存**不弹任何提示** —— 输入框本身就是"已保存"的证据，失败时才用 toast 报错。

### ③ 主操作按钮（通栏，高 38）

| 状态 | 文案 | 视觉 |
|---|---|---|
| 未连接 | `Connect` | 实心品牌绿 `#0B6B45`，白字 |
| 连接中 | `Cancel` | 实心琥珀（主题 Warning），白字 |
| 已连接 | `Disconnect` | 浅底 + 红色描边/红字（主题 Danger） |
| 断开中 | 保持 `Disconnect` 且禁用 | 灰色不可点 |
| 取消中 | `Cancel`（文案不变） | 状态卡改显示 `Cancelling` |

### ④ 面板入口（一排图标按钮，靠右）

- 4 个图标按钮，40 × 36，内边距 4×6，图标 19 号字重取主题文字色
- 图标是 **Lucide 风格的线性 SVG**（`assets/ui/*.svg`），画在 24×24 的画布里、
  墨迹占 20×20，四枚同一规格
- 只有图标，没有文字；**悬停提示**说出它是什么（`View log` / `Diagnostics` /
  `Routes` / `Settings`），并有无障碍标签
- 这是全 App **仅有的图标**（托盘除外，见第 7 节）

---

## 5. 运行状态矩阵（务必各出一张稿）

| 状态 | 状态点/托盘色 | 状态文字 | 副状态 | 主按钮 |
|---|---|---|---|---|
| 未连接 | 灰 `#8A9199` | Disconnected | — | Connect（绿） |
| 等待自动重连 | 灰 → 琥珀 | Reconnecting | `in 8 s` | Connect（绿） |
| 等待输入动态码 | 琥珀 `#C47F17` | Connecting | `Waiting for sign-in` | Cancel（琥珀） |
| 已提权、正在建隧道 | 琥珀 | Connecting | `MFA code accepted - establishing tunnel (this can take ~30s)...` | Cancel（琥珀） |
| 已连接 | 绿 `#12873E` | Connected | — | Disconnect（红描边） |
| 断开中 | 琥珀 | Disconnecting | — | Disconnect 禁用 |
| 取消中 | 琥珀 | Cancelling | — | Cancel（琥珀） |
| 工作进程失联 | 红 `#D92D20` | Worker unresponsive | — | Disconnect（红描边） |

> 异常时会有一句更长的说明替换副状态，例如
> `Cancel timed out - the worker is still running.` /
> `Disconnect timed out - the worker is still running; retry.`

---

## 6. 窗口与弹窗

### 6.1 主窗口

- 452 × 376 客户区，固定；系统标题栏，最大化按钮灰掉
- 内容用 `ui.Scroll` 包一层但**滚动条隐藏**（滚轮与键盘仍可滚动），保证任何一屏都不出现滚动条

### 6.2 四个面板窗口

四个面板**不是模态**，各自是一个独立的固定尺寸窗口，标题分别是
`Connection log` / `Diagnostics` / `Routes` / `Settings`。

| 面板 | 尺寸 | 结构 |
|---|---|---|
| Connection log | 640 × 460 | 顶部说明行 → `Level` 分段控件（`All` / `Info+` / `Warnings` / `Errors`）+ 搜索框 + `Latest` 按钮 → 日志列表（等宽 12，每行左侧 34 宽的级别标签 `DBG`/`INF`/`WRN`/`ERR`，行间 1px 分隔线，长行在 544 宽处折行）→ 右对齐按钮 `Copy` / `Export...` / `Clear` / `Close` → 状态说明行 |
| Diagnostics | 480 × 460 | 顶部说明行 → 检查结果列表（每行一个标记 `OK` / `!` / `X` + 名称 + 一行说明）→ 右对齐 `Run checks` / `Close` |
| Routes | 480 × 420 | 顶部说明行 → 路由列表（一行一条：`CIDR` + `host · 时间`，右侧一个安静的 `Remove` 文字按钮）→ 底部的添加输入框 + `Add` → 右对齐 `Clear all` / `Close` → 状态说明行 |
| Settings | 480 × 660 | 顶部说明行 → 可滚动的表单区（`ui.Form`，标签在左）：`VPN endpoint` / `SOCKS port` / `HTTP port` / `DTLS` / `Learn routes` / `Route prefix` / `Max routes` / `TTL days` / `Proxy domains` / `Extra routes` / `Campus DNS` / `DNS domains`；下面一组小标题 `This app`：`Start with Windows` / `Reconnect if dropped` / `Connect at start` → 右对齐 `Cancel` / `Save` → 状态说明行 |

- 所有列表都用官方的虚拟化列表组件，**滚动条隐藏**
- 面板里的消息走面板底部的说明行，不用 toast（toast 会被模态挡住）

### 6.3 动态码 `Verification code`（唯一的模态）

- 宽度 320 的白色卡片，居中，背后有官方模态遮罩
- 标题 `Verification code`（18 / Bold）
- 说明 `Enter the 6-digit code from Microsoft Authenticator.`（次级色）
- **错误行**（可空，红色）：`Previous code rejected - enter the current one.` / `The code must be exactly 6 digits.` / `Could not deliver the code.`
- 输入框：字号 22、等宽、居中、自动聚焦
- 一行小字 `The code is good for about 30 seconds.`（次级色，12）
- 提示 `Enter to submit · Esc gives up`（次级色，12）
- 按钮：`Submit`（主色），右下角

> **这是一个关口，不是提示**：关掉弹窗（Esc 或点外面）＝放弃这次连接，
> 没有"待会儿再输"。输入框里的 6 位码是唯一的出路。

---

## 7. 托盘图标（必须交付，且只有这里有图标）

- 形态：**盾牌**（HKU 盾徽的简化几何），极简线性描边
- **颜色即状态**：灰 / 绿 / 琥珀 / 红（与第 5 节一致），由同一个 SVG 渲染出四张 PNG
- 尺寸：PNG 为 64 × 64，由 MyGo 按 DPI 缩放到任务栏
- 悬停提示：`HKU VPN: disconnected` / `connecting` / `connected` / `worker unresponsive`
- 右键菜单：`Open HKU VPN`、`Exit`
- 左键单击：恢复主窗口
- **不要**设计 exe / 标题栏 / 界面内图标（界面里的四个面板图标已经是定稿）

---

## 8. 文案全集（请沿用英文原文）

**主界面**
```
HKU VPN
Disconnected / Reconnecting / Connecting / Connected / Disconnecting / Cancelling / Worker unresponsive
Waiting for sign-in
MFA code accepted - establishing tunnel (this can take ~30s)...
in 8 s
VPN address
Proxy
socks5://127.0.0.1:1080 · http://127.0.0.1:1088
Routes
3 learned routes · heartbeat OK / stale
HKU account
u1234567@connect.hku.hk
Portal PIN
Portal password
Connect / Cancel / Disconnect
```

**面板入口的提示**
```
View log
Diagnostics
Routes
Settings
```

**Connection log 窗口**
```
Connection log
This session
Level
All / Info+ / Warnings / Errors
Search the log
Latest
Copy / Copied
Export...
Clear
Close
No log lines yet
No lines at this level
```

**Diagnostics 窗口**
```
Diagnostics
Run checks
Close
No checks yet
running...
Launcher / Tunnel script / Account / Portal PIN / OpenConnect / gost / curl.exe / Proxy ports / Certificate pin / Learned routes
SOCKS5 port / HTTP port / SOCKS5 request / HTTP request / Egress address
```

**Routes 窗口**
```
Routes
Learned routes go through the tunnel, so the resources that need the campus exit are reachable.
1.2.3.0/24
no host recorded
just now / 5 min ago / 3 h ago / 2 d ago
Remove
Add
Clear all
Close
No learned routes yet
```

**Settings 窗口**
```
Settings
The advanced options are written to hku.env and apply to the next connect.
VPN endpoint / SOCKS port / HTTP port / DTLS / Learn routes / Route prefix / Max routes / TTL days / Proxy domains / Extra routes / Campus DNS / DNS domains
This app
Start with Windows / Reconnect if dropped / Connect at start
Cancel / Save
```

**动态码弹窗**
```
Verification code
Enter the 6-digit code from Microsoft Authenticator.
Previous code rejected - enter the current one.
The code must be exactly 6 digits.
Could not deliver the code.
The code is good for about 30 seconds.
Enter to submit · Esc gives up
Submit
```

**托盘 / 系统**
```
HKU VPN: disconnected / connecting / connected / worker unresponsive
Open HKU VPN
Exit
```

---

## 9. 交互流程

1. 编辑账号 / PIN → 停止输入约 0.7 秒后自动写盘（无提示）
2. 点 `Connect`（或 `Ctrl+Enter`）→ 系统 UAC 提权（界面进入连接中，按钮变 `Cancel`）
3. 工作进程要求动态码 → 弹出 `Verification code`
4. 输入 6 位码 → `Submit`（或回车）→ 弹窗关闭，进入建隧道阶段（约 20–30 秒）
5. 成功 → 状态变绿、显示 IP 与计时，按钮变 `Disconnect`
6. 点 `Disconnect` → 无需 UAC，等待后台清理，完成后回到未连接
7. 连接中点 `Cancel`、或在无弹窗时按 `Esc` → 中止本次连接
8. 动态码弹窗里按 `Esc` → 放弃这次连接（弹窗即关口）
9. 关闭窗口 → **最小化到托盘**，VPN 继续运行；托盘左键恢复，右键 `Exit` 才真正退出

---

## 10. 现有视觉 tokens（可整体替换，但请给新 token 表）

| 类别 | 现用值 |
|---|---|
| 状态点 / 文字 | `#8A9199`（未连接）· `#12873E`（已连接）· `#C47F17`（进行中）· `#D92D20`（失联） |
| 品牌绿（主按钮） | `#0B6B45`（hover `#0A5C3C`，pressed `#084B31`） |
| 危险红 | 主题 Danger / Warning / TextMuted，其余文字色全部取自官方主题 |
| 字体 | 界面 Segoe UI；数字/日志用系统等宽字体 |
| 字号 | 取自官方主题；日志 12 等宽、级别标签 11 等宽 Bold、MFA 输入 22 等宽 |

> 除强调色与四个状态色外，**所有颜色、字号、圆角、间距都来自官方主题**。
> 换主题时只要给出上表的映射即可，不必重画控件。

---

## 11. 技术边界（影响可落地性，请设计师留意）

- 渲染引擎：**MyGo 原生 UI**（Go 编写，Windows 上用 Direct3D 11 绘制，无 WebView、无 cgo）
- 组件：全部来自 MyGo 官方组件库（表单、输入框、按钮、列表、搜索、分段、模态、托盘），
  自定义仅限换强调色与少量容器排版
- 可落地：纯色、圆角、边框、**阴影、渐变、模糊、透明度**、过渡动画、SVG 图标
- 字体：系统界面字体（Windows 为 Segoe UI），等宽用系统等宽字体
- 窗口**不可调整大小**，没有滚动条；出框的内容用官方虚拟化列表或隐藏滚动条的滚动区
- 托盘图标必须是 **PNG**，由 MyGo 按 DPI 缩放；不需要 exe/标题栏图标

## 12. 请设计师交付

1. **8 张主界面状态稿**：未连接 / 等待重连 / 等待动态码 / 建隧道中 / 已连接 / 断开中 / 取消中 / 工作进程失联
2. **4 张面板窗口稿**：连接日志、诊断、路由、设置
3. **1 张弹窗稿**：动态码（含错误行状态）
4. **托盘图标一套**：4 种状态，附 16px 放大预览（确认可辨认）
5. **设计 token 表**：颜色、字号、间距、圆角、按钮尺寸
6. **标注稿**：间距与尺寸标注（逻辑像素）
7. 可选的交互说明：hover / 禁用 / 聚焦态

> 交付格式建议：Figma（含组件与变体）。实现方会按 1:1 还原。
