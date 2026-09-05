# 搭建步骤

[English](SETUP.md) · **中文**

可以用[脚本部署](docs/quickstart.zh-CN.md)，也可以按下面的页面手工搭。
选一条就行，不用做两遍。

目标是一台新开的 Vultr Ubuntu 24.04 服务器。下面会改 SSH 和防火墙，
别直接往已经跑着其他业务的机器上套。

## 手工路线

| 步骤 | 页面 | 做到什么算完成 |
|---|---|---|
| 1–8 | [账号与服务器](docs/01-prerequisites-and-servers.zh-CN.md) | 能用 SSH 登录 |
| 9–13 | [SSH 与防火墙](docs/02-server-hardening.zh-CN.md) | 重启后还能新建连接 |
| 14–19 | [Xray 与 REALITY](docs/03-vless-reality.zh-CN.md) | 服务运行，伪装目标正常应答 |
| 20–25 | [客户端](docs/04-client-setup.zh-CN.md) | 手机或电脑的出口 IP 变成服务器 IP |
| 26–28 | [出发前与用完后](docs/05-testing-and-teardown.zh-CN.md) | 知道怎么检查、替换和销毁 |

`[LOCAL]` 是你操作时用的电脑。Bash 命令需要 Linux 环境；
Windows 可以用 [WSL](https://learn.microsoft.com/windows/wsl/install)
里的 Ubuntu，WSL 就是在 Windows 上运行 Linux 的环境。原生 PowerShell 命令会单独标出。

`[SERVER]` 是远程 Vultr 服务器，这些命令用 `root` 执行。
如果以 `ops` 登录，先运行 `sudo -i`。

手工步骤里的 `SERVER_IP` 要换成服务器公网 IPv4。
自动化脚本把同一个地址记在 `.env.vultr` 的 `PRIMARY_IP` 中。
第一页的凭据表放进密码管理器，后面会用到。

每页末尾都有下一步。命令结果不对，先看[排障](TROUBLESHOOTING.zh-CN.md)，不要硬往下走。
参数为什么这么选，放在[技术笔记](RESEARCH.zh-CN.md)里，不夹在每两条命令中间。
