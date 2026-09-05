# When the connection stops working

**English** · [中文](TROUBLESHOOTING.zh-CN.md)

Do not start by deleting the server. A dead process, a firewall rule, and a
blocked network path can look much the same from a phone.

| What you see | Start here |
|---|---|
| Cannot reach the machine | [Server and port checks](#server-state) |
| TLS responds, but the proxy fails | [Camouflage versus authentication](#camouflage) |
| Connected, but some sites fail | [Routing and website checks](#websites) |
| Connected, but slow | [Speed](#speed) |
| Need a different instance | [Replacement](#replace-server) |

Replace `SERVER_IP` with your public IPv4. Server commands below use `sudo`
for an `ops` login. The [script setup](docs/quickstart.md) explains the read-only
`--verify-only` mode and the separate client-export option.

<a id="server-state"></a>

## Is the server listening?

In Vultr, check the instance's power state, billing, and the provider's
[status page](https://status.vultr.com/). Open **View Console** if SSH does not
work. A healthy VM status does not mean Xray is running.

On the server:

```bash
sudo systemctl status xray --no-pager
sudo journalctl -u xray -n 50 --no-pager
sudo ss -tlnp 'sport = :443'
timedatectl
```

If Xray is not active, use its log to fix the error.
For a configuration or permissions error, test as the service account:

```bash
sudo -u nobody xray run -test -c /usr/local/etc/xray/config.json
```

This assumes the pinned installer using `nobody`. If you changed the service
user, use that user instead. For an unsynchronized clock, check the time service:

```bash
timedatectl timesync-status
sudo journalctl -u systemd-timesyncd -n 30 --no-pager
```

From your computer, test TCP `443`. On Linux or macOS:

```bash
nc -vz SERVER_IP 443
```

On Windows PowerShell:

```powershell
Test-NetConnection SERVER_IP -Port 443
```

If Xray is listening but the port is unreachable, inspect `sudo nft list ruleset`
and any Vultr firewall attached to the instance. Then try a second access
network. A failed ping alone is not evidence of a blocked IP; ICMP can be filtered.

<a id="camouflage"></a>

## TLS worked. Did authentication?

Run the [camouflage check](docs/03-vless-reality.md#camouflage) from outside the
server. The URL must name the target site, while `--resolve` points that
hostname to your server. Using an IP as the URL changes the request and can
produce a misleading certificate error.

If the target does not answer, check that the server itself can still reach
that target. A changed website or expired certificate is not fixed by
regenerating your proxy credentials.

If camouflage works but the client fails, compare these fields with the
server configuration:

| Client field | Must match |
|---|---|
| UUID | The configured client ID |
| Flow | `xtls-rprx-vision` |
| SNI | An entry in `serverNames` |
| `pbk` | The public key paired with the server's private key |
| `sid` | An entry in `shortIds` |

Check automatic time on both devices. For a sing-box client, also check
`minClientVer`:

```bash
sudo grep -n minClientVer /usr/local/etc/xray/config.json
```

This setup uses `1.8.1` for the pinned sing-box client's advertised version.
That is not a universal fix for all TLS errors.
[The technical notes](RESEARCH.md#reality-version) explain the warning and
the compatibility trade-off. The operating system alone does not identify
which proxy core a client uses.

<a id="websites"></a>

## Only some websites fail

Look at the client's routing and DNS logs. Did the request take the proxy
route or the direct route? Did name resolution succeed? Importing a VLESS link
does not install routing rules.

The supplied Xray config blocks proxy access to Chinese and private IP ranges.
Domestic services need the client's direct-routing rules; see
[client setup](docs/04-client-setup.md).

### Cloudflare asks for a checkbox

If completing it lets you browse normally, leave the server alone.
A website's challenge can depend on the IP, browser, session, and its own
rules. A checkbox does not identify which one caused it.

For a loop, allow JavaScript and cookies for that site and avoid changing exits
mid-challenge. If it works directly, a site-specific direct rule is an option.
Replacing the instance may change an IP-related outcome, but is no guarantee.
More CPU or a different proxy port does not change the exit IP's reputation.

<a id="speed"></a>

## It connects, but it is slow

Compare the same test on the same device with the proxy on and off, then try
Wi-Fi instead of cellular. Keep the test destination and time close enough
that the numbers are comparable.

Before upgrading the server, inspect CPU use and the current TCP settings:

```bash
top
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc
```

Run those on the server while traffic is flowing. Low CPU usage does not locate
the bottleneck, but it gives little reason to buy more CPU.
The [recorded measurements](RESEARCH.md#performance) illustrate the distinction.

<a id="replace-server"></a>

## Replacing the instance

Do this when you have decided to replace it, not as the first connectivity
test. A new IP may help with a path or reputation problem; it cannot fix every
failure.

For a scripted deployment, use the original checkout and keep the old instance
until the new one works. The two instances overlap briefly during replacement.

1. Copy the local settings:

```bash
cp .env.vultr .env.replacement
chmod 600 .env.replacement
```

2. Edit `.env.replacement`. Change `VULTR_INSTANCE_LABEL` to an unused label
   beginning with `personal-vpn-`, for example `personal-vpn-replacement`.
   Keep the SSH and REALITY credentials.

3. Create the replacement:

```bash
ENV_FILE=.env.replacement ./scripts/bring-up.sh
```

4. Wait for `READY`, import the newly generated client link, and confirm the
   new exit IP from your device.

5. Preview deletion using the **old** settings:

```bash
ENV_FILE=.env.vultr ./scripts/bring-down.sh --dry-run
```

Only if that shows the old instance, permanently delete it:

```bash
ENV_FILE=.env.vultr ./scripts/bring-down.sh --yes
```

6. Make the replacement's settings the default and regenerate the import files:

```bash
mv .env.replacement .env.vultr
./scripts/bring-up.sh --verify-only --export-client
```

Simply rerunning `bring-up.sh` with the old label would reuse the old instance,
not allocate a new address.

For a manual deployment, create the new instance in Vultr and follow the
[SSH](docs/02-server-hardening.md) and [Xray](docs/03-vless-reality.md) pages.
Update the client and confirm it works before deleting the old server.
