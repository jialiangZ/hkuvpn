# HKU VPN 桌面端 · 设计说明（交付设计师）

> 用途：这是实现方对**当前可用版本**的完整拆解。设计师可以据此重做视觉，不必先读代码。
> 交付目标：一套现代、简洁、易读的浅色界面；保持本文列出的信息与操作不变。

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
| 窗口尺寸 | 480 × 620（逻辑像素） | 固定尺寸，不可缩放；可整体调整，但需保证下列内容不滚动 |
| 标题栏 | 标准 Windows 标题栏 | 仅显示文字 “HKU VPN”，**无任何图标**（应用图标已按需求删除，请不要再设计 App 图标） |
| 背景 | 浅灰 `#F4F5F7` | 内容以白色卡片承载 |
| 安全边距 | 左右 28，顶部 26 | 卡片之间 16–18 |
| 圆角 | 卡片 14，按钮 9–10，输入框 8 | |

设计稿请按 **100% 缩放**出图（逻辑像素 = CSS px）；小尺寸托盘图标另见第 7 节。

---

## 3. 主界面解剖（自上而下）

```
┌──────────────────────────────────────────────┐
│  HKU VPN                                     │  ← ① 页头
│  HKU Portal VPN · vpn2fa.hku.hk              │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │ ● Disconnected              --:--:--   │  │  ← ② 状态卡
│  │ Not connected                          │  │
│  │ Proxy   socks5://127.0.0.1:1080 · …    │  │
│  │ Routes  -                              │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  ┌ Account ───────────────────────────────┐  │  ← ③ 账号卡
│  │ HKU account                            │  │
│  │ [ u3015850@connect.hku.hk            ] │  │
│  │ Portal PIN                             │  │
│  │ [ ••••••••••••••                     ] │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  ┌──────────────── Connect ───────────────┐  │  ← ④ 主操作
│  └────────────────────────────────────────┘  │
│                                              │
│  [ 📄 View log ]                             │  ← ⑤ 次要操作
│  Closing this window keeps the VPN …         │  ← ⑥ 提示行
└──────────────────────────────────────────────┘
```

| # | 区块 | 作用 |
|---|---|---|
| ① | 页头 | 产品名 + 服务器副标题。无 logo（不要加图标） |
| ② | 状态卡 | 一眼看清“现在是什么状态、隧道地址、已连接多久、代理与路由” |
| ③ | 账号卡 | 常驻的 HKU 账号与 Portal PIN 输入，编辑后自动保存 |
| ④ | 主操作 | 唯一的强按钮，随状态变形：Connect / Cancel / Disconnect |
| ⑤ | 次要操作 | 打开连接日志 |
| ⑥ | 提示行 | 一行说明；保存成功或校验失败时临时替换 |

---

## 4. 组件详表

### ① 页头

| 元素 | 内容 | 样式现状 |
|---|---|---|
| 产品名 | `HKU VPN` | 20 / Semibold / `#0F172A` |
| 副标题 | `HKU Portal VPN · vpn2fa.hku.hk` | 13 / Regular / `#6B7280` |

> 原设计有 46×46 的品牌徽标，已按需求移除；如需新版可提方案，但**应用图标与窗口图标保持空白**。

### ② 状态卡（白色卡片）

| 元素 | 内容 | 说明 |
|---|---|---|
| 状态点 | 9–11 px 圆点 | 颜色 = 状态色，见第 5 节 |
| 状态文字 | `Disconnected` / `Connecting` / `Connected` / `Disconnecting` / `Worker unresponsive` | 15 / Semibold |
| 计时 | `--:--:--` 或 `00:12:34` | 右对齐，等宽字体（Consolas）14 / `#8A9199` |
| 主值 | `Not connected` / `Waiting for sign-in` / 隧道 IP `10.64.199.140` | 未连接 19 / Regular 灰；已连接 26 / Semibold 深色 |
| 明细 1 | `Proxy` + `socks5://127.0.0.1:1080 · http://127.0.0.1:1088` | 标签 13 灰，值 13 深灰 |
| 明细 2 | `Routes` + `3 learned routes · heartbeat OK` | 同上；异常时显示 `heartbeat stale` |

### ③ 账号卡（白色卡片）

| 元素 | 内容 |
|---|---|
| 卡片标题 | `Account`（15 / Semibold） |
| 字段 1 标签 | `HKU account` |
| 字段 1 占位 | `u1234567@connect.hku.hk` |
| 字段 2 标签 | `Portal PIN` |
| 字段 2 占位 | `Portal password` |
| 输入框 | 高 38，圆角 8，1px 边框；聚焦时边框变品牌色；PIN 以圆点掩码显示 |

> 行为：**编辑后自动保存**（无保存按钮）。保存成功底部提示行短暂显示 `Account details saved.`

### ④ 主操作按钮

| 状态 | 文案 | 视觉 |
|---|---|---|
| 未连接 | `Connect` | 实心品牌绿 `#0B6B45`，白字 17 / Semibold，高 52 |
| 连接中 | `Cancel` | 实心琥珀 `#B45309` |
| 已连接 | `Disconnect` | 白底 + 红色描边/红字 `#B42318` |
| 断开中 | 保持 `Disconnect` 且禁用 | 灰色不可点 |

### ⑤ 次要操作

`View log`：白底描边小按钮，高 40，左侧一个日志线条图标。

### ⑥ 提示行

12 / `#9AA1A9`，单行，内容随场景切换：

- 默认：`Closing this window keeps the VPN running in the tray.`
- 保存成功：`Account details saved.`
- 账号为空点连接：`Enter your HKU account first.`

---

## 5. 运行状态矩阵（务必各出一张稿）

| 状态 | 状态点/托盘色 | 状态文字 | 主值 | 主按钮 |
|---|---|---|---|---|
| 未连接 | 灰 `#8A9199` | Disconnected | Not connected | Connect（绿） |
| 等待输入动态码 | 琥珀 `#C47F17` | Connecting | Waiting for sign-in | Cancel（琥珀） |
| 已提权、正在建隧道 | 琥珀 | Connecting | `MFA code accepted - establishing tunnel…` | Cancel（琥珀） |
| 已连接 | 绿 `#12873E` | Connected | 隧道 IP（大号） | Disconnect（红描边） |
| 断开中 | 琥珀 | Disconnecting | 原 IP 保留 | Disconnect 禁用 |
| 工作进程失联 | 红 `#D92D20` | Worker unresponsive | `Connected` 或最后 IP | Disconnect（红描边） |

> 副状态提示（如 `Disconnect timed out - the worker is still running; retry.`）会替换提示行文案。

---

## 6. 弹窗（两种）

### 6.1 连接日志 `Connection log`

- 尺寸约 440 × 400，白卡，圆角 14，背后遮罩 `rgba(15,23,42,0.2)`
- 标题 `Connection log`（19 / Semibold）
- 日志区：等宽 13，深灰字，浅底 `#FAFBFC`，纵向滚动，长行自动换行
- 底部右对齐按钮：`Clear`（次要）、`Close`（主色）
- 交互：点击遮罩可关闭；打开时下层界面不可点

### 6.2 动态码 `Verification code`

- 尺寸约 400 × 250
- 标题 `Verification code`（19 / Semibold）
- 说明 `Enter the 6-digit code from Microsoft Authenticator.`（13 灰）
- **错误行**（可空，红色 13）：`Previous code rejected - enter the current one.` / `The code must be exactly 6 digits.` / `Could not deliver the code.`
- 输入框：6 位、字号 20、等宽、居中、宽 220 高 44
- 按钮：`Submit`（主色，122 × 44）
- 提示：`Enter to submit · Esc to cancel`（12 灰）

---

## 7. 托盘图标（必须交付，且只有这里有图标）

- 形态建议：**盾牌 + 书本**的极简标记（VPN 安全 + 学术），也可另提方案
- **颜色即状态**：灰 / 绿 / 琥珀 / 红（与第 5 节一致）
- 尺寸：16、20、24、32、40、48、64 px 各一帧，打包成多尺寸 ICO
- 关键要求：
  - 16 px 下仍可辨认轮廓；细线在 16–24 px 会被丢弃，请提供**简化版**
  - 浅色与深色任务栏都要有足够对比（现方案用状态色填充 + 白色书本 + 白色描边）
- 悬停提示：`HKU VPN: disconnected` / `connecting` / `connected` / `worker unresponsive`
- 右键菜单：`Open HKU VPN`、`Exit`
- 左键单击：恢复主窗口
- **不要**设计 exe / 标题栏 / 界面内图标（已明确移除）

---

## 8. 文案全集（请沿用英文原文）

**主界面**
```
HKU VPN
HKU Portal VPN · vpn2fa.hku.hk
Disconnected / Connecting / Connected / Disconnecting / Worker unresponsive
Not connected
Waiting for sign-in
MFA code accepted - establishing tunnel (DTLS handshake + route learning can take ~30s)...
Proxy
socks5://127.0.0.1:1080 · http://127.0.0.1:1088
Routes
%d learned routes · heartbeat OK / stale
Account
HKU account
u1234567@connect.hku.hk
Portal PIN
Portal password
Connect / Cancel / Disconnect
View log
Closing this window keeps the VPN running in the tray.
Account details saved.
Enter your HKU account first.
```

**日志弹窗**
```
Connection log
Clear
Close
```

**动态码弹窗**
```
Verification code
Enter the 6-digit code from Microsoft Authenticator.
Previous code rejected - enter the current one.
The code must be exactly 6 digits.
Could not deliver the code.
Submit
Enter to submit · Esc to cancel
```

**托盘 / 系统**
```
HKU VPN: disconnected / connecting / connected / worker unresponsive
Open HKU VPN
Exit
```

---

## 9. 交互流程

1. 编辑账号 / PIN → 失焦即自动保存（底部提示）
2. 点 `Connect` → 系统 UAC 提权（此时界面进入连接中，按钮变 `Cancel`）
3. 工作进程要求动态码 → 弹出 `Verification code`
4. 输入 6 位码 → `Submit`（或回车）→ 弹窗关闭，进入建隧道阶段（约 20–30 秒）
5. 成功 → 状态变绿、显示 IP 与计时，按钮变 `Disconnect`
6. 点 `Disconnect` → 无需 UAC，等待后台清理，完成后回到未连接
7. 连接中点 `Cancel` 或动态码弹窗按 Esc → 中止本次连接
8. 关闭窗口 → **最小化到托盘**，VPN 继续运行；托盘左键恢复，右键 `Exit` 才真正退出

---

## 10. 现有视觉 tokens（可整体替换，但请给新 token 表）

| 类别 | 现用值 |
|---|---|
| 背景 / 卡片 / 边框 | `#F4F5F7` / `#FFFFFF` / `#E6E8EC` |
| 主文字 / 次文字 / 弱文字 | `#0F172A` / `#6B7280` / `#9AA1A9` |
| 品牌绿（主按钮） | `#0B6B45`（hover `#0A5C3C`） |
| 危险红 | `#B42318` / 描边 `#F0B4AE` |
| 连接中琥珀 | `#B45309` / 状态点 `#C47F17` |
| 已连接绿（状态点） | `#12873E` |
| 未连接灰 | `#8A9199` |
| 字体 | 界面 Segoe UI；数字/日志 Consolas |
| 字号 | 20 / 19 / 17 / 15 / 14 / 13 / 12 / 11 |

---

## 11. 技术边界（影响可落地性，请设计师留意）

- 渲染引擎是 **RmlUi + OpenGL2**，样式是 CSS 的一个子集：
  - 支持：纯色、1px 边框、圆角、字号/字重、透明度、hover/active、简单过渡
  - **不支持**：渐变、阴影、模糊、毛玻璃、复杂滤镜、SVG 运行时渲染
  - 因此请用**扁平色块 + 描边 + 圆角 + 留白**表达层次，不要依赖投影/渐变
- 界面内如需图形，请交付 **PNG/TGA（2x 图）**，不要只给 SVG
- 窗口固定尺寸；内容不允许出现滚动条
- 字体仅保证：Segoe UI（常规/粗体）、Consolas

---

## 12. 请设计师交付

1. **6 张主界面状态稿**：未连接 / 等待动态码 / 建隧道中 / 已连接 / 断开中 / 工作进程失联
2. **2 张弹窗稿**：连接日志、动态码（含错误行状态）
3. **托盘图标一套**：4 种状态 × 7 个尺寸，附 16px 放大预览（确认可辨认）
4. **设计 token 表**：颜色、字号、间距、圆角、按钮尺寸
5. **标注稿**：间距与尺寸标注（逻辑像素）
6. 可选的交互说明：hover / 禁用 / 聚焦态

> 交付格式建议：Figma（含组件与变体）。实现方会按 1:1 还原。
