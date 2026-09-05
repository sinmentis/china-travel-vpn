# 04 - 连上客户端

[English](04-client-setup.md) · **中文**

每台设备选一个 App 就够了，不需要为了完成搭建再装一个备用客户端。
服务器测通以后，手机还是要自己连一次。

## 20. 准备连接信息

跑过脚本，就用仓库目录里的 `primary-ios.local.txt` 或 `primary-ios.local.png`。
文件名虽然带 iOS，里面其实是 VLESS 分享链接，其他支持这个格式的客户端也能导入。

按[手工步骤](03-vless-reality.zh-CN.md)搭的，用之前记下的参数：

| 字段 | 值 |
|---|---|
| 协议 | VLESS |
| 地址 | `SERVER_IP` |
| 端口 | `443` |
| UUID / ID | `VPN_UUID` |
| Flow | `xtls-rprx-vision` |
| 传输 | TCP |
| TLS 安全设置 | REALITY |
| SNI / server name | `REALITY_TARGET` |
| Public key / `pbk` | `REALITY_PUBLIC_KEY` |
| Short ID / `sid` | `REALITY_SHORT_ID` |
| Fingerprint | `chrome` |

SNI 是 TLS 握手里发送的域名。这里填伪装目标域名，不是服务器 IP。
公钥用 Xray 输出里标成 `Password (PublicKey)` 的那项，不是 `Hash32`。

## 21. Windows

安装 [v2rayN](https://github.com/2dust/v2rayN)。从剪贴板导入 VLESS 链接，
或按上表手工添加 VLESS 服务器，选中后启用系统代理。

系统代理只影响遵循系统代理设置的应用，不代表电脑上的所有进程都走了隧道。

## 22. Android

husi 这类客户端可以直接导入 VLESS 链接。添加节点、选中连接，再批准 Android 的 VPN 权限。

如果选官方 sing-box App，它需要的是完整的 sing-box JSON 配置。
脚本生成的 VLESS 链接不是这个格式。出发前把安装 APK 留一份，方便以后安装。

## 23. iPhone

1. 安装 [Streisand](https://apps.apple.com/app/streisand/id6450534064)。
2. 点 `+`，扫描二维码或导入剪贴板链接。
3. 点击连接，批准 iOS 的 VPN 权限。

手工部署的就按第 20 步填参数。
脚本跑在远程电脑上时，把导入文件私下传过来，不要上传到公开的二维码网站。

在手机浏览器打开 `https://api.ipify.org`，看到的地址应与服务器公网 IPv4 一致。
Wi-Fi 和蜂窝网络各试一次。IP 地理库标的城市可能不准，比较地址就行，不必纠结地图。
App 在出发前装好，商店是否上架与账号地区有关。

## 24. 国内服务走直连

分流就是决定哪些流量走代理。导入链接只包含节点信息，**不包含完整的路由和 DNS 规则**。

在客户端的路由设置里，把能直连的国内服务设为直连。
先从一个自己常用的域名开始，再看客户端日志确认实际走向。
不同 App 的菜单不一样，本仓库没有提供一份适用于所有客户端的国内分流模板。

## 25. 保存可用的配置

把链接或导出的配置放进密码管理器。里面有凭据，变成二维码也不会更安全。

下一页：[检查与收尾](05-testing-and-teardown.zh-CN.md)。
