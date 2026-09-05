# 用脚本搭起来

[English](quickstart.md) · **中文**

脚本负责服务器。Vultr 账号、API key 和手机上的客户端还是要准备，
它不会替你注册账号，也不会替你操作手机。

## 1. 打开 Linux 终端

本机、虚拟机或 Windows 的 [WSL](https://learn.microsoft.com/windows/wsl/install)
都可以，下面按 Ubuntu 24.04 写。脚本会下载 Linux 版测试客户端，
不能直接在原生 PowerShell 或 macOS 中运行。

装好本地工具，再拉取仓库：

```bash
sudo apt update
sudo apt install -y git curl python3 openssh-client openssl coreutils util-linux tar qrencode
git clone https://github.com/sinmentis/china-travel-vpn.git
cd china-travel-vpn
```

已经拉过仓库就用原来的目录，不用再克隆一份。

## 2. 允许这台机器调用 Vultr API

还没有 Vultr 账号的话，先注册并添加支付方式。
主页有可选的[推荐链接和赠金说明](../README.zh-CN.md#trial-credit)。

进入 **Account → API**，启用 API 并复制 key。
在 **Access Control** 里添加这台机器的公网 IPv4，后面带 `/32`。用下面的命令查：

```bash
curl -4fsS https://api.ipify.org
printf '\n'
```

如果你是 SSH 进虚拟机操作，这条命令就在虚拟机里跑。
要放行的是虚拟机的出口地址，不是笔记本的。不要填 `0.0.0.0/0`。

## 3. 运行脚本

```bash
./scripts/bring-up.sh
```

第一次运行会问 API key 和 REALITY 目标域名。
目标是用来伪装的公开 HTTPS 网站，不需要是你自己的域名。
先找一个通过[目标检查](03-vless-reality.zh-CN.md#target)的网站，
只填域名，不带 `https://` 和路径。

默认开大阪、Ubuntu 24.04、`vc2-1c-1gb`。脚本会安装 Xray、重启服务器，再实际连一次隧道。
等它输出 `READY`。中途报错可能仍留下计费中的实例，离开前去控制台看一眼。

已有同名实例时会复用，不会自动给你换 IP。重新跑完整部署也可能让现有连接短暂断开。

## 4. 导入客户端

文件在运行脚本的仓库目录里：

| 文件 | 用途 |
|---|---|
| `primary-ios.local.txt` | VLESS 导入链接 |
| `primary-ios.local.png` | 二维码，装了 `qrencode` 才会生成 |
| `.env.vultr` | API key、SSH 私钥密码和服务器凭据 |

接着看[客户端配置](04-client-setup.zh-CN.md)。链接和二维码都相当于密码。
这些文件被 Git 忽略，但没有加密；把 `.env.vultr` 和 `~/.ssh/travel_ed25519` 安全备份好。

## 以后检查连接

```bash
./scripts/bring-up.sh --verify-only
```

这个模式只检查已有实例，不会创建、启动或重新配置服务器。
保存的凭据、实例记录、SSH 主机密钥和客户端导入文件都不改。
缺少密钥或实例已关机，会直接报错。

检查成功后，如果确实要重新生成客户端导入文件，显式加上这个选项：

```bash
./scripts/bring-up.sh --verify-only --export-client
```

凭据要完整保存。漏掉其中一项会报错，不会偷偷换一套新凭据，让原来的客户端突然断开。

用完后按[销毁步骤](05-testing-and-teardown.zh-CN.md#teardown)收尾。
