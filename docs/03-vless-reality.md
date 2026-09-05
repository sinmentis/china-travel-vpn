# 03 - Run Xray

**English** · [中文](03-vless-reality.zh-CN.md)

Continue after [SSH and firewall setup](02-server-hardening.md).
Run `[SERVER]` commands as `root`; use `sudo -i` if you logged in as `ops`.

There are two different checks at the end: whether the camouflage target answers
and whether a client can authenticate. The first does not prove the second.

<a id="target"></a>

## 14. Choose the target site `[LOCAL]`

Choose a public HTTPS site reachable from the Osaka server. Avoid Apple and
iCloud for this setup. A site's name appearing in a tutorial is not a
substitute for checking it.

Replace `example.jp` below with your candidate. Run the same checks on the
server before using it:

```bash
CANDIDATE=example.jp

openssl s_client -connect "$CANDIDATE:443" -servername "$CANDIDATE" \
  -tls1_3 -alpn h2 </dev/null 2>&1 | grep -E 'TLSv1.3|ALPN|Verify return code'
curl -s -o /dev/null -w 'http=%{http_code}\n' "https://$CANDIDATE/"
```

For this guide, all four need to appear: `TLSv1.3`, `ALPN protocol: h2`,
`Verify return code: 0 (ok)`, and `http=200`. Try another site if one is missing.
Save the hostname as `REALITY_TARGET`.

## 15. Install the pinned version `[SERVER]`

Use the same installer commit and checksum as `bring-up.sh`.

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

The checksum must pass and the version must begin with `Xray 26.7.28`.
If either fails, stop here.

## 16. Generate the credentials `[SERVER]`

Enter the target hostname from step 14 when prompted.

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

Save the output in your password manager. Keep this terminal open: step 17
uses the variables you just set. The private key stays on the server.

## 17. Write the configuration `[SERVER]`

This is the same Xray configuration the script generates. The opening checks
stop the block if any required variable is empty.

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

It should print `Config written`. Leave the port at `443` and flow at
`xtls-rprx-vision`. The `minClientVer` value is a
[compatibility choice](../RESEARCH.md#reality-version), not a general tuning knob.
This setup connects directly to Xray; do not add an nginx layer to it.

## 18. Test as the user that runs it `[SERVER]`

The pinned installer uses `nobody`. Testing only as `root` can miss a file
permission error.

```bash
sudo -u nobody xray run -test -c /usr/local/etc/xray/config.json
```

Look for `Configuration OK.`. The warning about changing `minClientVer` is
expected for this configuration; the technical notes explain the trade-off.
Other errors need fixing before starting the service.

```bash
systemctl enable --now xray
systemctl restart xray
systemctl is-active xray
ss -tlnp | grep -E ':(80|443)\s'
```

You should see `active`, with Xray listening on `80` and `443`.
The restart loads the new configuration even if the installer already started it.

<a id="camouflage"></a>

## 19. Check from outside the server `[LOCAL]`

Replace both values below:

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

You want `http=200`, a certificate for the target site, and
`Verify return code: 0 (ok)`. The port `80` result should be `200`, `301`, or `302`.
If not, [check the service and target](../TROUBLESHOOTING.md#camouflage).

This request used no proxy credentials. It checked the camouflage path, not
your authenticated tunnel. Next, [connect the client](04-client-setup.md).
