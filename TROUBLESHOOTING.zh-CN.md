# 连不上时，先看哪里

[English](TROUBLESHOOTING.md) · **中文**

别先删服务器。进程没启动、防火墙挡住了、线路不通，在手机上可能看起来都一样。

| 现象 | 从这里开始 |
|---|---|
| 连不到机器 | [服务器和端口](#server-state) |
| TLS 有响应，但代理连不上 | [伪装与认证](#camouflage) |
| 连上了，只有部分网站不通 | [路由和网站](#websites) |
| 能用，但慢 | [速度](#speed) |
| 确实要换一台机器 | [替换服务器](#replace-server) |

把 `SERVER_IP` 换成公网 IPv4。下面的服务器命令按 `ops` 登录后使用 `sudo` 写。
脚本的只读 `--verify-only` 模式和单独的导出选项，在[脚本部署页](docs/quickstart.zh-CN.md)有说明。

<a id="server-state"></a>

## 服务器到底有没有在监听

先到 Vultr 看实例是否开机、账单是否正常，也看看[服务状态页](https://status.vultr.com/)。
SSH 不通就打开 **View Console**。云主机状态健康，不代表 Xray 进程在跑。

在服务器上执行：

```bash
sudo systemctl status xray --no-pager
sudo journalctl -u xray -n 50 --no-pager
sudo ss -tlnp 'sport = :443'
timedatectl
```

Xray 没启动，就先按日志处理。
涉及配置和权限时，用服务账号检查：

```bash
sudo -u nobody xray run -test -c /usr/local/etc/xray/config.json
```

这里按固定安装器使用的 `nobody` 写。改过服务用户，就换成实际用户。
时间没同步的话，继续看时间服务：

```bash
timedatectl timesync-status
sudo journalctl -u systemd-timesyncd -n 30 --no-pager
```

再从自己电脑测 TCP `443`。Linux 或 macOS 用：

```bash
nc -vz SERVER_IP 443
```

Windows PowerShell 用：

```powershell
Test-NetConnection SERVER_IP -Port 443
```

Xray 在监听，端口却连不到，就检查 `sudo nft list ruleset`，以及实例是否绑定了 Vultr 防火墙，
然后换一个接入网络试试。只有 ping 不通，不能据此判断 IP 被封，ICMP 本来就可能被过滤。

<a id="camouflage"></a>

## TLS 通了，认证呢

从服务器外面跑一次[伪装检查](docs/03-vless-reality.zh-CN.md#camouflage)。
URL 里要写目标域名，`--resolve` 再把它指到你的服务器。
直接把 IP 写成 URL，会改变请求，也可能得到误导性的证书错误。

目标站点没有应答，就看服务器自己是否还能访问它。
网站行为变了、证书过期了，重新生成代理凭据没有用。

伪装正常但客户端连不上，再逐项对照：

| 客户端字段 | 要匹配什么 |
|---|---|
| UUID | 服务端配置的客户端 ID |
| Flow | `xtls-rprx-vision` |
| SNI | `serverNames` 中的一项 |
| `pbk` | 与服务端私钥配对的公钥 |
| `sid` | `shortIds` 中的一项 |

确认两端都开启自动时间。如果客户端用 sing-box，还要看 `minClientVer`：

```bash
sudo grep -n minClientVer /usr/local/etc/xray/config.json
```

这里的 `1.8.1` 对应固定版本 sing-box 宣告的客户端版本，
不是所有 TLS 错误的通用修复。[技术笔记](RESEARCH.zh-CN.md#reality-version)里有告警和取舍。
不能只看操作系统，就断定一个 App 用了哪个代理内核。

<a id="websites"></a>

## 只有部分网站不通

看客户端的路由和 DNS 日志。请求到底走了代理还是直连？域名有没有解析成功？
导入 VLESS 链接不会顺便装好分流规则。

这份 Xray 配置会阻止通过代理访问中国和私有 IP 段。
国内服务需要在客户端设直连，见[客户端配置](docs/04-client-setup.zh-CN.md)。

### Cloudflare 让勾一个框

勾完能正常访问，就先别动服务器。
网站验证可能与 IP、浏览器、会话状态和站点自己的规则有关。
一个勾选框不能告诉你具体是哪项触发的。

如果反复循环，确认该站能使用 JavaScript 和 cookie，验证过程中别反复切换出口。
直连能用的话，可以单独给这个站设直连。
换实例可能改变与 IP 有关的结果，但没有保证；加 CPU 或换代理端口不会改变出口 IP 的信誉。

<a id="speed"></a>

## 能用，但慢

同一台设备、同一个测速目标，开关代理各测一次，再把蜂窝网络换成 Wi-Fi。
测试时间尽量接近，不然几个数字可能根本没有可比性。

升级服务器之前，在流量正在经过时看 CPU 和 TCP 设置：

```bash
top
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
```

这两条在服务器上跑。CPU 很闲，不能直接告诉你瓶颈在哪，
但也没有多少理由因此去买更多 CPU。[记录过的那次测速](RESEARCH.zh-CN.md#performance)就是这个区别。

<a id="replace-server"></a>

## 替换服务器

这是决定换机以后做的事，不是第一项连通性检查。
新 IP 可能改善某条线路或信誉问题，但不是什么故障都能靠它解决。

脚本部署的，在原来的仓库目录操作。新机能用以前保留旧机；
替换期间会短暂同时存在两台。

1. 复制本地配置：

```bash
cp .env.vultr .env.replacement
chmod 600 .env.replacement
```

2. 编辑 `.env.replacement`，把 `VULTR_INSTANCE_LABEL` 改成一个未使用的
   `personal-vpn-` 前缀标签，例如 `personal-vpn-replacement`。
   SSH 和 REALITY 凭据保留。

3. 创建替换机：

```bash
ENV_FILE=.env.replacement ./scripts/bring-up.sh
```

4. 等到 `READY`，导入新生成的客户端链接，在设备上确认出口 IP 已经换成新机的地址。

5. 使用**旧配置**预览删除目标：

```bash
ENV_FILE=.env.vultr ./scripts/bring-down.sh --dry-run
```

只有显示的是旧实例，才执行永久删除：

```bash
ENV_FILE=.env.vultr ./scripts/bring-down.sh --yes
```

6. 把新机配置设为默认，再生成导入文件：

```bash
mv .env.replacement .env.vultr
./scripts/bring-up.sh --verify-only --export-client
```

如果只是拿旧标签重新跑 `bring-up.sh`，它会复用旧实例，不会申请新地址。

手工部署的，在 Vultr 新开实例后，按[SSH](docs/02-server-hardening.zh-CN.md)
和 [Xray](docs/03-vless-reality.zh-CN.md)两页配置。
更新客户端、确认可用，再删旧服务器。
