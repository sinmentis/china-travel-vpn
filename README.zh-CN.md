# China Travel VPN：回国上网，先用一台服务器

[English](README.md) · **中文**

一台 Vultr 大阪服务器，1 GB 内存，跑 Xray。这个仓库放的是搭建、客户端配置和销毁步骤。
没有管理面板。

传输方式有两种，部署时选一个。

| | REALITY（默认） | [CDN 套壳](docs/06-cdn-fronting.zh-CN.md) |
|---|---|---|
| 速度 | 快，一跳直达 | 慢，多绕一跳 |
| 扛得住 IP 被封 | 不行 | 可以 |
| 需要域名 | 不需要 | 需要 |

默认是 VLESS + Vision + REALITY，监听 TCP `443`，直连服务器。
这条路更快，除了服务器本身什么都不需要。它的弱点是一切都押在一个地址上。
那个地址一旦被封，协议再好也救不回来——包就是到不了。

另一条路把 Cloudflare 挡在前面，走 VLESS over WebSocket。
你交出去的是一个主机名而不是地址，也就没有源站 IP 可封。
代价是延迟和一个域名。能用 REALITY 就先用，不行了再换。

一台机器也意味着它挂了就会断，没有另一个节点自动接管。这里的取舍很直接：
少维护一套东西，接受出问题时要花时间修。不是单机更可靠，而是把维护范围限制在一台机器。

## 现在能确认什么

已记录的检查覆盖部署、重启恢复，以及 sing-box 和 Streisand 的认证连接，两条线路都测过。
还不能据此判断国内接入网络、晚高峰或长期使用的表现。
REALITY 能减少隧道流量与普通 TLS 流量的一些差异，但服务器 IP 仍然可以被封。
CDN 那条路存在的理由正是这个。

搭建时有个小问题值得记下来：用 `root` 检查配置，会漏掉权限错误。
安装器让 Xray 以 `nobody` 运行，它读不了 `root:root 600` 的配置文件。
所以脚本现在用服务实际运行的用户做检查。对这个项目来说，这种检查比挂一个“生产可用”的徽章有用。

[技术笔记](RESEARCH.zh-CN.md)里还写了 `minClientVer` 的兼容问题，以及测速数字到底能说明什么。

## 怎么搭

从[脚本部署](docs/quickstart.zh-CN.md)开始。里面有本地 Linux 环境要求、
Vultr API 的设置，以及脚本会问的两个值。

```bash
./scripts/bring-up.sh
```

脚本会创建或复用指定实例，配置 Xray，通过隧道发一次真实请求，再生成客户端导入链接。
**再跑一次不会换 IP。** 换服务器要走[单独的替换流程](TROUBLESHOOTING.zh-CN.md#replace-server)。

想改成 Cloudflare 挡在前面，部署时指定一次传输方式：

```bash
TRANSPORT=cdn ./scripts/bring-up.sh
```

这条路需要一个托管在 Cloudflare 的域名和一个 API 令牌。
[CDN 页面](docs/06-cdn-fronting.zh-CN.md)讲了这两样，
还有那个一设错就会让一切悄悄失效的控制台选项。

想自己敲命令，就看[手工步骤](SETUP.zh-CN.md)，内容一样，拆成了几页短的。
服务器已经好了，直接看[客户端配置](docs/04-client-setup.zh-CN.md)。
连不上时看[排障](TROUBLESHOOTING.zh-CN.md)。

<a id="trial-credit"></a>

## 费用，还有那 $300 赠金

举个费用例子：按记录时的 `$0.007/小时` 算，运行 `504` 小时约 `$3.53`。
税费、超额流量和额外资源另算，开机前还是以 Vultr 当前报价为准。

符合条件的新账号可以通过这个 [Vultr 推荐链接](https://www.vultr.com/?ref=9921378-9J)
领取 **$300 体验金**，足够覆盖试用期内这台小服务器约一个月的计算资源费用。
需要绑定有效信用卡或 PayPal；重复账号不符合条件，未用完的赠金在 30 天后过期，
具体以 Vultr 当时的活动规则为准。符合返佣条件的注册可能给仓库维护者带来推荐收入。

比金额更值得记住的是到期日。每月约 `$5` 的服务器用不完 `$300`，但剩下的赠金照样会过期，
服务器也不会因此停止计费。[用完要销毁](docs/05-testing-and-teardown.zh-CN.md#teardown)，只关机不行。

## 修改脚本

回归测试使用假的 API 响应和临时文件，不需要 Vultr 账号，也不会创建云资源。

```bash
python3 -m unittest discover -s tests -v
shellcheck -x scripts/*.sh scripts/lib/*.sh
```

[CI](.github/workflows/ci.yml) 还会扫描 Git 历史里的凭据。

MIT 许可证，见 [LICENSE](LICENSE)。
