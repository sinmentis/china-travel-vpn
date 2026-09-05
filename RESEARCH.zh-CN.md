# 搭这套东西时，几个容易判断错的地方

[English](RESEARCH.md) · **中文**

这里关注的不是哪家云排第一，而是几个容易忽略的小问题：
配置用错用户检查也能通过，TLS 返回真证书也可能走错了连接路径，
服务器测得很快，手机却不一定快。

下面的技术记录整理于 2026-09-04，不包含长期使用、国内家宽或移动网络的测量结果。

## 为什么做到一台就停

项目只支持单人自建代理，不做面向多用户的托管服务。
只用一台 Vultr，部署和恢复流程都短一些；同时也留下了单点故障。两件事都要承认。

记录时大阪的 `vc2-1c-1gb` 约 `$0.007/小时`。
例如运行 `504` 小时，计算资源费用约 `$3.53`，税费和附加项另算。
按小时计费，让短暂开一台替换机的成本不高，但不能保证下一个 IP 在某条网络上就可用。

大阪是默认部署区域，不是对所有地区做完对照测试后选出的冠军。
这些测试还不足以支持“最适合中国线路”的说法。

<a id="protocol"></a>

## REALITY 省掉了什么，没省掉什么

Xray 是服务端程序，VLESS 是代理协议，Vision 是它使用的流模式。
REALITY 负责这套配置里的 TLS 伪装和认证。

实际省下来的一件事，是不用给服务器注册域名、维护公开证书。
没有通过 REALITY 认证的连接，可以被转发到真实 HTTPS 目标站点，
于是探测请求能看到那个站点自己的证书和内容。

这不等于每个数据包都与浏览器完全一样，也不隐藏服务器 IP。
随便一个协议改到 `443`，也不会因此变成 HTTPS。
这里让 Xray 直接在 `443` 处理 REALITY，不额外套反向代理，少引入一个变量。
`80` 端口也转发到同一个目标。

设计本身看[上游 REALITY 文档](https://github.com/XTLS/REALITY)，
这里实际使用的内容看[手工配置](docs/03-vless-reality.zh-CN.md)。

<a id="service-user"></a>

## root 读得了，不代表 Xray 读得了

最初的手工步骤把 Xray 配置权限设成了 `root:root 600`。
文件里有私钥，这么设看起来很合理。准备部署时查了一下服务，才发现少考虑了一件事：
它以 `nobody` 运行。

在服务器上看：

```bash
systemctl show xray -p User -p Group
sudo -u nobody xray run -test -c /usr/local/etc/xray/config.json
```

用 `root` 测，只能说明 root 读得进去、解析得出来，证明不了服务账号也能读。
对这里固定安装器使用的 `nobody`/`nogroup`，配置现在设为 `root:nogroup 640`。
自动化脚本则直接查询服务用户和组，不假定服务以 root 运行。

SSH 也有同类问题。改完配置，原来的会话还连着，并不说明下一次能登录。
关掉旧会话之前，新开一条连接试一下。

<a id="reality-version"></a>

## 真证书，也可能是一个错误的成功信号

直接用 `curl` 访问服务器，不会带上 REALITY 凭据。
拿到目标站点的证书和 HTTP `200`，说明伪装路径通了，不说明你的代理客户端认证成功了。

`minClientVer` 就容易在这里绕进去。Xray `v26.7.28` 在没有填写这个字段时会提示：

```text
[Warning] infra/conf: REALITY: The default minimal client version is
Xray-core v26.3.27, other clients may be refused to connect
```

而 [sing-box v1.14.0 的 REALITY 客户端](https://github.com/SagerNet/sing-box/blob/v1.14.0/common/tls/reality_client.go#L186-L188)
把宣告的版本直接写在代码里：

```go
hello.SessionId[0] = 1
hello.SessionId[1] = 8
hello.SessionId[2] = 1
```

它报的是 `1.8.1`，不是 sing-box 的发布版本号。
所以这套服务端配置把 `minClientVer` 设成 `1.8.1`，兼容这个客户端。
这个组合已经发过带认证的真实请求，出口 IP 与 Vultr 服务器一致。

代价也写在 Xray 的告警里：

```text
[Warning] infra/conf: REALITY: Changing "minClientVer" will increase the
likelihood of your server's IP being blocked by the GFW
```

这是兼容性取舍，不是一个能让默认配置变得更安全的诀窍。
连不上时不要顺手把下限继续调低。如果所有客户端都使用兼容的 Xray 内核，
更严格的默认值可能才合适。该看客户端用的内核，而不是拿操作系统划线。
换版本后还得重新确认。

还有个命名细节：这个版本的 `xray x25519` 输出中，
客户端 `pbk` 要填标成 `Password (PublicKey)` 的那项，不是 `Hash32`。

```text
PrivateKey: <server-private-key>
Password (PublicKey): <client-public-key>
Hash32: <other-derived-value>
```

<a id="performance"></a>

## 加内存不会缩短网络路径

手机用蜂窝网络测到过约 `32 Mbps`。在考虑换大机器之前，先比较了几条路径。
下载目标都是 Cloudflare 的测速端点：

| 路径 | 当次下载速度 |
|---|---:|
| Vultr 服务器直接下载 | `2181.1 Mbps` |
| Azure VM 直接下载 | `2061.3 Mbps` |
| 同一台 Azure VM 经 Vultr 的 REALITY 隧道下载 | `152.8 Mbps` |

每次下载 `50 MB`，不是长时间压测。客户端和网络也与手机不同。
这组数字只能说明整套服务没有固定卡在 `32 Mbps`，还不能定位手机的瓶颈。

随后连续通过隧道下载时，抽样看到 Xray 的 CPU 平均约 `0.6%`，峰值 `2%`。
服务器原本就启用了 TCP 拥塞控制算法 BBR，以及 `fq` 队列调度。
当时没有证据支持继续加 CPU 或内存。

下一项值得做的比较在手机上：同一个网络、同一个测速目标，开关代理各测一次，再换 Wi-Fi 重复。
在这之前升级套餐，只是在没有证据的地方改变量。

## 路由图不是采购合同

调研时用过 RIPEstat 的 [ASN 邻接数据](https://stat.ripe.net/data/asn-neighbours/data.json?resource=AS20473)。
ASN 是路由网络的编号，Vultr 的网络关联 `AS20473`。
BGP 是网络之间交换路由的协议，能提供一些拓扑线索。

但看见邻接关系，不能直接推导出服务商买了什么；没看见，也不能证明某种线路服务不存在。
它更不告诉你中国运营商会为回程选择哪条路径。

这类数据适合拿来调查，不足以推出“所有主流云都不买优质线路”这种结论。
从实际使用的接入网络测一次，比拿一张不完整的图下定论更有用。

<a id="versions"></a>

## 固定的是输入，不是结论

自动化部署使用这些版本：

| 组件 | 固定版本 |
|---|---|
| Xray-core | [`v26.7.28`](https://github.com/XTLS/Xray-core/releases/tag/v26.7.28) |
| sing-box 测试客户端 | [`v1.14.0`](https://github.com/SagerNet/sing-box/releases/tag/v1.14.0) |
| Xray 安装脚本 | [`e741a4f`](https://github.com/XTLS/Xray-install/tree/e741a4f56d368afbb9e5be3361b40c4552d3710d) |

脚本会用固定 SHA-256 校验安装器，Xray 安装器会校验发行包，
sing-box 下载则与发行附件提供的摘要比较。
这是哈希校验，不是数字签名，也仍然依赖来源本身没有被篡改。

固定版本是为了能复现结果，不是承诺这个版本永久安全，或与未来所有客户端都兼容。
当前配置使用 `raw` 和 `target`，旧示例里可能写成 `tcp` 和 `dest`。
按目标版本用一份完整配置，不要把不同时期的片段混在一起。

## 赠金最值得记住的是到期日

账号 API 把可用余额表示成负数。保护脚本按
`max(0, -balance - pending_charges)` 计算剩余额度。
这个数字不包含赠金什么时候过期，所以截止时间要另外填写。

[Vultr 关机仍然计费](https://docs.vultr.com/support/platform/billing/are-stopped-instances-still-billed-on-vultr)。
[保护脚本](scripts/vultr-credit-guard.sh)到阈值或截止时间后会请求删除实例，
但它是外部措施，不是硬性消费上限。运行它的机器、凭据和 API 访问都必须持续可用。

还没测到的部分也很明确：在中国大陆，从预期使用的网络、在不同时间段实际连接的表现。
部署完成，不能替这些结果签字。
