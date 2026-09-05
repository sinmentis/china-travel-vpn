# 01 - 先开一台服务器

[English](01-prerequisites-and-servers.md) · **中文**

这是手工路线。已经用[脚本](quickstart.zh-CN.md)部署过的，直接去[配客户端](04-client-setup.zh-CN.md)。

## 1. 准备这些东西 `[LOCAL]`

Vultr 支持的支付方式、验证器 App、密码管理器，以及 SSH 客户端。
不用买域名。还不熟悉终端环境的话，先看[这里](../SETUP.zh-CN.md)。

## 2. 注册账号 `[LOCAL]`

1. 在 [Vultr](https://www.vultr.com/) 注册，填写真实资料。
2. 添加支付方式。
3. 开启验证器双因素认证，保存恢复码。

可选的[推荐赠金](../README.zh-CN.md#trial-credit)有资格和到期限制。
手工搭建不需要 API key。

## 3. 留好控制台入口 `[LOCAL]`

把 Vultr 控制台加入书签。第 6 步开机后，先打开一次 **View Console**。
SSH 不通时，可以从这里进机器，不用急着重建。

如果打算靠本国 SIM 卡漫游访问控制台，出发前确认已开通，也看清资费。
它是另一个访问途径，不是保证能恢复的保险。

## 4. 生成 SSH 密钥 `[LOCAL]`

已经有 `~/.ssh/travel_ed25519` 就复用，不要覆盖。没有再运行：

```bash
ssh-keygen -t ed25519 -C "travel-2026" -f ~/.ssh/travel_ed25519
```

设置密码短语，把私钥备份到密码管理器。

## 5. 上传公钥 `[LOCAL]`

把 `~/.ssh/travel_ed25519.pub` 的内容放进 Vultr 的 **SSH Keys** 页面。
不带 `.pub` 的那个文件留在自己电脑上。

## 6. 开通实例 `[LOCAL]`

选择 **Cloud Compute → Shared CPU**，按下面填写：

| 设置 | 值 |
|---|---|
| 区域 | Osaka（`itm`） |
| 系统 | Ubuntu 24.04 LTS x64 |
| 套餐 | `vc2-1c-1gb` |
| Label | `personal-vpn-primary` |
| SSH key | 第 5 步的公钥 |
| IPv6、备份、付费附加项 | 关闭 |

记录时的计算资源价格是 `$5/月`，约 `$0.007/小时`，开机前核对当前报价。
脚本还在用 `personal-vpn-` 标签前缀，不要为了和仓库同名而改掉。

## 7. 记下几个值 `[LOCAL]`

这张表放进密码管理器。还空着的几项会在[Xray 那页](03-vless-reality.zh-CN.md)生成。

```text
SERVER_IP            = <public IPv4 from Vultr>
REALITY_TARGET       = <step 14>
VPN_UUID             = <step 16>
REALITY_PUBLIC_KEY   = <step 16>
REALITY_SHORT_ID     = <step 16>
```

## 8. 先登录一次 `[LOCAL]`

把下面的 `SERVER_IP` 换成实际公网 IPv4：

```bash
ssh -i ~/.ssh/travel_ed25519 root@SERVER_IP 'echo OK; uname -m'
```

应该看到 `OK` 和 `x86_64`。没有就先处理 SSH，不急着往下搭。

下一页：[SSH 与防火墙](02-server-hardening.zh-CN.md)。
