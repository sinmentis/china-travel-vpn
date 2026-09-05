# 03 - 让 Xray 跑起来

[English](03-vless-reality.md) · **中文**

接着[SSH 与防火墙](02-server-hardening.zh-CN.md)那页做。
`[SERVER]` 命令用 `root` 执行；以 `ops` 登录的话，先 `sudo -i`。

最后要分清两件事：伪装目标是否应答，以及客户端是否通过认证。前者成功，不代表后者成功。

<a id="target"></a>

## 14. 选一个目标站点 `[LOCAL]`

选大阪服务器能够访问的公开 HTTPS 网站。这套配置先避开 Apple 和 iCloud。
教程里出现过某个域名，不代表你现在就能拿来用。

把下面的 `example.jp` 换成候选域名。确定采用前，也在服务器上跑一遍相同检查：

```bash
CANDIDATE=example.jp

openssl s_client -connect "$CANDIDATE:443" -servername "$CANDIDATE" \
  -tls1_3 -alpn h2 </dev/null 2>&1 | grep -E 'TLSv1.3|ALPN|Verify return code'
curl -s -o /dev/null -w 'http=%{http_code}\n' "https://$CANDIDATE/"
```

这份指南要求四项都出现：`TLSv1.3`、`ALPN protocol: h2`、
`Verify return code: 0 (ok)` 和 `http=200`。缺一项就换个站点。
把选中的域名记为 `REALITY_TARGET`。

## 15. 安装固定版本 `[SERVER]`

安装脚本的提交和校验值与 `bring-up.sh` 保持一致。

```bash
(
set -euo pipefail
INSTALLER_COMMIT=e741a4f56d368afbb9e5be3361b40c4552d3710d
INSTALLER_SHA256=7f70c95f6b418da8b4f4883343d602964915e28748993870fd554383afdbe555
INSTALL_DIR=$(mktemp -d)
trap 'rm -f "$INSTALL_DIR/install-release.sh"; rmdir "$INSTALL_DIR"' EXIT
curl -fsSL \
  "https://raw.githubusercontent.com/XTLS/Xray-install/$INSTALLER_COMMIT/install-release.sh" \
  -o "$INSTALL_DIR/install-release.sh" &&
printf '%s  %s\n' "$INSTALLER_SHA256" "$INSTALL_DIR/install-release.sh" | sha256sum -c - &&
TERM=xterm bash "$INSTALL_DIR/install-release.sh" install --version v26.7.28
xray version
)
```

校验必须通过，版本应以 `Xray 26.7.28` 开头。任何一项不对，先停在这里。

## 16. 生成凭据 `[SERVER]`

提示输入目标域名时，填第 14 步选好的那个。

```bash
set +o history

KEYS=$(xray x25519)
REALITY_PRIVATE_KEY=$(echo "$KEYS" | awk '/^PrivateKey:/{print $2}')
REALITY_PUBLIC_KEY=$(echo "$KEYS"  | awk '/^Password/{print $3}')
VPN_UUID=$(xray uuid)
REALITY_SHORT_ID=$(openssl rand -hex 8)
read -rp 'REALITY target hostname: ' REALITY_TARGET

cat <<EOF
REALITY_TARGET      = $REALITY_TARGET
VPN_UUID            = $VPN_UUID
REALITY_PUBLIC_KEY  = $REALITY_PUBLIC_KEY
REALITY_SHORT_ID    = $REALITY_SHORT_ID
EOF
```

把输出存进密码管理器。这个终端先留着，第 17 步要用刚才的变量。
私钥留在服务器上。

## 17. 写配置 `[SERVER]`

这份 Xray 配置与脚本生成的内容一致。开头几行会检查必要变量，漏了就停止这一块，不写空配置。

```bash
(
set -eu
: "${VPN_UUID:?Complete step 16 first}"
: "${REALITY_TARGET:?Complete step 16 first}"
: "${REALITY_PRIVATE_KEY:?Complete step 16 first}"
: "${REALITY_SHORT_ID:?Complete step 16 first}"
umask 077
cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },

  "inbounds": [
    {
      "tag": "reality-in",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${VPN_UUID}", "flow": "xtls-rprx-vision" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "raw",
        "security": "reality",
        "realitySettings": {
          "target": "${REALITY_TARGET}:443",
          "serverNames": [ "${REALITY_TARGET}" ],
          "privateKey": "${REALITY_PRIVATE_KEY}",
          "shortIds": [ "${REALITY_SHORT_ID}" ],
          "minClientVer": "1.8.1"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ],
        "routeOnly": true
      }
    },
    {
      "tag": "camouflage-80",
      "listen": "0.0.0.0",
      "port": 80,
      "protocol": "dokodemo-door",
      "settings": { "address": "${REALITY_TARGET}", "port": 80, "network": "tcp" }
    }
  ],

  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],

  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "outboundTag": "block", "inboundTag": [ "reality-in" ], "ip": [ "geoip:cn", "geoip:private" ] },
      { "outboundTag": "block", "protocol": [ "bittorrent" ] }
    ]
  }
}
EOF

chown root:nogroup /usr/local/etc/xray/config.json
chmod 640 /usr/local/etc/xray/config.json

printf 'Config written\n'
)
```

应该输出 `Config written`。端口保持 `443`，flow 保持 `xtls-rprx-vision`。
`minClientVer` 是一个[兼容性取舍](../RESEARCH.zh-CN.md#reality-version)，不是通用调优参数。
这套部署直接连 Xray，不要另外加一层 nginx。

## 18. 用服务实际运行的用户检查 `[SERVER]`

这里固定的安装器使用 `nobody`。只用 `root` 检查，可能漏掉文件权限问题。

```bash
sudo -u nobody xray run -test -c /usr/local/etc/xray/config.json
```

应看到 `Configuration OK.`。关于修改 `minClientVer` 的告警是这个配置预期会有的，
取舍写在技术笔记里。其他错误先解决，再启动。

```bash
systemctl enable --now xray
systemctl restart xray
systemctl is-active xray
ss -tlnp | grep -E ':(80|443)\s'
```

应该看到 `active`，以及 Xray 监听 `80` 和 `443`。
这里显式重启一次，避免安装器之前已启动服务，却没加载新配置。

<a id="camouflage"></a>

## 19. 从服务器外面访问一次 `[LOCAL]`

替换下面两个值：

```bash
REALITY_TARGET=your-target-from-step-14.jp
SERVER_IP=your-server-ip

curl -sS -o /dev/null -w 'http=%{http_code}\n' \
  "https://$REALITY_TARGET/" --resolve "$REALITY_TARGET:443:$SERVER_IP"

openssl s_client -connect "$SERVER_IP:443" -servername "$REALITY_TARGET" \
  </dev/null 2>&1 | grep -E 'subject=|Verify return code'

curl -sS -o /dev/null -w 'http80=%{http_code}\n' \
  -H "Host: $REALITY_TARGET" "http://$SERVER_IP/"
```

应得到 `http=200`、目标站点的证书，以及 `Verify return code: 0 (ok)`。
`80` 端口应返回 `200`、`301` 或 `302`。
不一致就先查[服务和目标站点](../TROUBLESHOOTING.zh-CN.md#camouflage)。

注意，这个请求没带代理凭据，只测了伪装路径。
下一步[连接客户端](04-client-setup.zh-CN.md)，才能知道认证后的隧道是否可用。
