# <img src="docs/images/docker-vpn-icon.png" width="44" alt="Docker-VPN 图标"> Docker-VPN（HKU 版）

**访问港大校园网，同时继续使用你原来的上网线路。**

[English](Readme.md) · [简体中文](README.zh-CN.md) · [项目网站](https://rqhu1995.github.io/docker-vpn/) · [详细指南](docs/guide.zh-CN.md)

查校内资源、SSH 到实验室、远程控制学校电脑时，还想让浏览器和 AI 工具继续走原来的网络？Docker-VPN 把 HKU VPN 放进 Docker，提供本地代理，由你选择哪些请求进入校园网，主机默认路由保持不变。

## 能帮你做什么

| 你的需求 | 用法 |
|---|---|
| 访问 HKU 网站和校内资源 | 给应用设置代理，或按域名分流 |
| SSH / 远程桌面连接学校电脑 | 让目标主机的连接走 HKU |
| 学校电脑上的开发工具需要本机代理 | 通过反向 SSH 借用本机已有代理（进阶） |

![校园请求经 Docker-VPN 到 HKU；其他请求继续使用原有网络或代理](docs/images/routing-flow-zh.png)

容器内由 OpenConnect 建立 VPN，本机通过 SOCKS5 / HTTP 端口使用隧道。**应用可以直接设置代理；按网站或 IP 自动分流时，再接入 Clash 或 Surge。**

## 快速上手

准备好可用的 **Docker**、`openssl`、已开通 VPN 的 HKU 账号、**Portal 静态 PIN** 和 **Microsoft Authenticator 验证码**。当前入口为 `vpn2fa.hku.hk`，仍需 MFA；实际连通性取决于所在网络。

<details>
<summary>还没有 Docker？</summary>

macOS 可使用 Colima（需先安装 Homebrew）：

```bash
brew install colima docker
colima start --cpu 2 --memory 2 --disk 20 --vm-type vz --mount-type virtiofs
```

也可使用 Docker Desktop；Linux 使用 Docker Engine；Windows 在 Docker Desktop 启用 WSL2 集成后，从 WSL2 运行以下命令。

</details>

### 1. 构建镜像

确认 `docker info` 正常，再执行：

```bash
git clone https://github.com/rqhu1995/docker-vpn.git ~/docker-vpn
cd ~/docker-vpn
docker build -t local/vpn .
```

### 2. 填写账号和 PIN

```bash
mkdir -p ~/.vpn
cp ~/docker-vpn/examples/hku.env.example ~/.vpn/hku.env
nano ~/.vpn/hku.env
```

将 `HKU_USER` 改为自己的 HKU 账号，例如 `youruid@connect.hku.hk`。然后创建 PIN 文件：

```bash
(umask 077; touch ~/.vpn/hku.pass)
chmod 600 ~/.vpn/hku.pass
nano ~/.vpn/hku.pass
```

在文件中只填写 **Portal 静态 PIN**，不要填写动态验证码。Nano 按 `Ctrl+O`、`Enter` 保存，`Ctrl+X` 退出。账号和 PIN 保存在仓库外的 `~/.vpn/`。

### 3. 连接并验证

```bash
~/docker-vpn/bin/hkuvpn
```

出现 `Response:` 时输入 Authenticator 当前六位验证码。保持终端开启；`Ctrl+C` 断开连接。

在**第二个终端**测试：

```bash
curl -x socks5h://127.0.0.1:1080 -I https://www.hku.hk/
```

返回 HTTP 响应头说明代理请求已通；具体校内资源仍取决于账号权限。失败时查看[常见故障](docs/guide.zh-CN.md#常见故障)。

## 连接后怎么用

| 接入方式 | 地址或配置 |
|---|---|
| 应用直接使用 SOCKS5 | `127.0.0.1:1080` |
| 应用直接使用 HTTP 代理 | `127.0.0.1:1088` |
| Clash Verge Rev / Mihomo 自动分流 | [配置示例](examples/clash-verge.yaml) · [接入步骤](docs/guide.zh-CN.md#clash-verge-rev--mihomo) |
| Surge 自动分流 | [配置示例](examples/surge.conf) · [接入步骤](docs/guide.zh-CN.md#surge) |
| SSH / 远程桌面 | [连接学校电脑](docs/guide.zh-CN.md#ssh-与远程桌面) |

代理默认只供本机使用，提供 TCP 转发；`socks5h` 会把 DNS 查询也交给代理。使用分流客户端时，**VPN 服务器自身必须走直连或已有代理**，避免绕回 Docker-VPN；示例已包含相应规则。

日常操作：

```bash
~/docker-vpn/bin/hkuvpn            # 连接
~/docker-vpn/bin/hkuvpn --status   # 查看状态
~/docker-vpn/bin/hkuvpn --stop     # 停止
~/docker-vpn/bin/hkuvpn --recover  # 修复 Docker / Colima，不触发 MFA
```

[安装简短的 `hkuvpn` 命令](docs/guide.zh-CN.md#安装简短的-hkuvpn-命令) · [修改默认端口](docs/guide.zh-CN.md#直接使用本地代理)

## 进阶：让学校电脑借用本机代理

开发工具运行在学校电脑上，但可用的代理在你的本机？建立反向 SSH 隧道后，远端进程就能使用本机已有代理访问外部服务。

![学校电脑上的开发工具经反向 SSH 使用本机已有代理访问外部服务](docs/images/reverse-proxy-flow-zh.png)

本机需同时保持 HKU VPN、SSH 隧道和原有代理在线。只在本机浏览器使用 AI 网页时，无需这一步。[查看配置与验证步骤 →](docs/guide.zh-CN.md#通过反向-ssh-为学校电脑提供代理)

---

更多内容：[故障排查](docs/guide.zh-CN.md#常见故障) · [安全说明](docs/guide.zh-CN.md#安全说明) · [兼容性与版本](docs/guide.zh-CN.md#兼容性与版本)

基于 [ethack/docker-vpn](https://github.com/ethack/docker-vpn) 改造。仓库尚未提供 `LICENSE`，详见[来源与许可证](docs/guide.zh-CN.md#来源与许可证)。
