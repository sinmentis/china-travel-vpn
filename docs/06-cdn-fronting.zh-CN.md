# 躲到 CDN 后面

[English](06-cdn-fronting.md) · **中文**

REALITY 保护的是**协议**，对**地址**毫无办法。服务器 IP 一旦进了黑名单，
握手做得再完美也没用——包根本到不了。这一页就是为这种情况准备的。

办法是别再把服务器地址交出去。流量先打到 Cloudflare，再由它转给你的服务器。
要封就得连带封掉半个互联网都在用的地址段，代价高得多。

代价是速度。每个包多绕一跳，CDN 还要自己做一次 TLS 终止，
比直连明显慢是正常的。能用 REALITY 就先用，这条路留着等它失效时再换。

| | REALITY（默认） | CDN 套壳 |
|---|---|---|
| 速度 | 快，一跳直达 | 慢，多绕一跳 |
| 扛得住 IP 被封 | 不行 | 可以 |
| 需要域名 | 不需要 | 需要 |
| 暴露源站地址 | 会 | 不会 |

## 先准备这些

一个托管在 Cloudflare 的域名。在哪注册都行，但 NS 必须指向 Cloudflare，
它才能代理流量。免费套餐就够。如果你手上还没有域名，这是这条路唯一的真实开销，
一年通常也就几美元。

挑一个主机名。用裸域名或者它下面的任意子域都可以，`edge.example.com` 就挺好，
名字无聊比取得花哨强。

然后在 **Manage Account → API Tokens → Create Token** 里选 **Create Custom Token**
建一个令牌，需要三项权限：

| 权限 | 用途 |
|---|---|
| Zone → Zone → Read | 找到主机名所属的 zone |
| Zone → DNS → Edit | 把主机名指向服务器 |
| Zone → SSL and Certificates → Edit | 签发源站证书 |

**Zone Resources** 限定到你要用的那一个 zone。令牌只显示一次，记得复制。

有一个设置弄错就全盘不通：**SSL/TLS → Overview** 里的加密模式必须是
**Full** 或 **Full (strict)**。设成 **Flexible** 时，Cloudflare 会用明文 HTTP
连你的服务器，服务器用 TLS 回应，连接就这么断了，而且不会给出有用的报错。

## 部署

```bash
TRANSPORT=cdn ./scripts/bring-up.sh
```

脚本会问主机名和 API 令牌，存进 `.env.vultr`，之后这个设置就固定了。
后续再跑不需要再带这个变量：

```bash
./scripts/bring-up.sh --verify-only
```

这一条命令背后，脚本做了这些事：

1. 逐级向上匹配域名，找到主机名所属的 Cloudflare zone。
   如果域名压根没加到 Cloudflare，会在这一步就失败，此时还没创建任何资源。
2. 照常创建并加固服务器。
3. 为主机名添加一条**已代理**的 `A` 记录。代理是整件事的关键，
   没开代理的记录等于把你想藏的地址直接公布出去。
4. **在服务器上**生成私钥，只把签名请求发给 Cloudflare，再把签回来的证书装上。
   私钥自始至终没有离开过那台机器。
5. 把 Xray 配成 VLESS over WebSocket + TLS。
6. 把 `443` 端口限制为只接受 Cloudflare 自己的地址段。
7. 通过 Cloudflare 发一次真实的认证请求，核对出口 IP。

第 6 步值得多说一句。源站只跟 Cloudflare 通信，就没有理由接受别人。
别人扫你服务器地址时看到的是一个关闭的端口，而不是一个可供指纹识别的 TLS 服务。
地址段是部署时拉取的；Cloudflare 以后要是加了新段，重跑一次脚本即可。

证书用的是 [Cloudflare 源站证书](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)。
只有 Cloudflare 信任它，而这里要的就是这个——访客看到的是 Cloudflare 自己的公共证书。
有效期 15 年，不存在忘记续期的问题。

## 手工版本

想自己配的话，入站长这样。path 是一个共享密钥：对不上的流量就不是你的流量。

```json
{
  "listen": "0.0.0.0",
  "port": 443,
  "protocol": "vless",
  "settings": {
    "clients": [{ "id": "YOUR_UUID" }],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "ws",
    "security": "tls",
    "tlsSettings": {
      "alpn": ["http/1.1"],
      "certificates": [
        {
          "certificateFile": "/usr/local/etc/xray/tls/origin.crt",
          "keyFile": "/usr/local/etc/xray/tls/origin.key"
        }
      ]
    },
    "wsSettings": { "path": "/YOUR_SECRET_PATH" }
  }
}
```

注意这里少了什么：没有 `flow`。Vision 需要裸 TCP 流，WebSocket 不是。
硬加上去连接就废了。

生成私钥并申请证书，把主机名换成你自己的：

```bash
sudo install -d -m 750 /usr/local/etc/xray/tls
sudo openssl ecparam -genkey -name prime256v1 \
  -out /usr/local/etc/xray/tls/origin.key
sudo openssl req -new -key /usr/local/etc/xray/tls/origin.key \
  -subj "/CN=edge.example.com" -outform PEM
```

把输出的请求贴进 **SSL/TLS → Origin Server → Create Certificate**，
再把签好的证书存到 `/usr/local/etc/xray/tls/origin.crt`。
两个文件都要属主 `root`、Xray 服务组可读、权限 `640`。

## 验证

客户端链接照常写到 `primary-ios.local.txt`，里面是主机名而不是 IP。
导入方式跟 [REALITY 链接](04-client-setup.zh-CN.md)一样。

想确认 Cloudflare 真的挡在前面，查一下这个主机名。
返回的地址应该属于 Cloudflare，而不是你的服务器：

```bash
dig +short edge.example.com
```

如果返回的是服务器真实地址，说明这条记录没开代理。
先去 Cloudflare 控制台改好再用。

## 有哪些地方不一样

免费套餐下，空闲的 WebSocket 连接约 100 秒后会被关掉。
客户端会自己重连，所以表现是短暂卡一下，而不是断掉。

销毁时也会一并释放 Cloudflare 侧的资源。`bring-down.sh` 会删掉 DNS 记录、
吊销源站证书——留一条指向已回收地址的记录，以后是别人的麻烦。

走这条线路时如果隧道不通，地址基本不再是嫌疑对象。
先看[排障](../TROUBLESHOOTING.zh-CN.md)，不要急着换服务器。

下一步：[客户端配置](04-client-setup.zh-CN.md)。
