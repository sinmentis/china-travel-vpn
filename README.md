# China Travel VPN

**English** · [中文](README.zh-CN.md)

One small Vultr server in Osaka, 1 GB of memory, and Xray. This repository
contains the setup, client configuration, and teardown instructions. There is
no management panel.

It ships two ways of carrying the traffic, and you pick one when you deploy.

| | REALITY (default) | [CDN fronting](docs/06-cdn-fronting.md) |
|---|---|---|
| Speed | Fast, one hop | Slower, extra hop |
| Survives an IP block | No | Yes |
| Needs a domain | No | Yes |

The default is VLESS + Vision + REALITY on TCP `443`, straight to the server.
It is the faster of the two and needs nothing but the server itself. Its
weakness is that everything depends on one address staying reachable. When
that address gets blocked, the protocol cannot save it — the packets simply
stop arriving.

The other route puts Cloudflare in front and speaks VLESS over WebSocket. You
hand out a hostname instead of an address, so there is no origin IP to block.
It costs latency and a domain. Use REALITY while it works and switch when it
does not.

One server also means one point of failure. If it stops working, there is no
second endpoint waiting to take over. That is the trade-off here: fewer things
to maintain, in exchange for accepting downtime while fixing the connection.

## What has actually worked

The documented checks cover deployment, reboot recovery, and authenticated
connections with sing-box and Streisand, on both routes. They do not establish
performance on mainland Chinese access networks, at peak hours, or over
extended use. REALITY reduces some differences between the tunnel and ordinary
TLS traffic; it does not make the server unblockable. That is exactly why the
CDN route exists.

One useful detail from the setup: checking the configuration as `root` would
have missed a permissions problem. The installer runs Xray as `nobody`, which
cannot read a `root:root` file with mode `600`. The scripts now test the config
as the service user. Small checks like that are more useful here than a
"production-ready" badge.

The [technical notes](RESEARCH.md) cover that issue, the `minClientVer`
compatibility setting, and what the speed measurements do and do not tell us.

## Getting it running

Start with the [script setup](docs/quickstart.md). It includes the local Linux
requirements, Vultr API access, and the two values the script asks for.

```bash
./scripts/bring-up.sh
```

The script creates or reuses the configured instance, sets up Xray, checks a
real connection through it, and writes a client import link. Running it again
does **not** rotate the IP. Replacing a server is a
[separate procedure](TROUBLESHOOTING.md#replace-server).

To put Cloudflare in front instead, set the transport once:

```bash
TRANSPORT=cdn ./scripts/bring-up.sh
```

That route needs a domain on Cloudflare and an API token. The
[CDN page](docs/06-cdn-fronting.md) covers both, plus the one dashboard
setting that silently breaks everything if it is wrong.

Prefer to run the commands yourself? The [manual setup](SETUP.md) has the same
steps as short pages. If the server is already running, go straight to
[client setup](docs/04-client-setup.md). For a broken connection, use the
[troubleshooting notes](TROUBLESHOOTING.md).

<a id="trial-credit"></a>

## Cost, including the trial credit

For example, `504` hours at the recorded rate of `$0.007/hour` comes to about
`$3.53` of compute. Taxes, extra transfer, and other resources are separate.
Check the current price in Vultr before creating the instance.

Eligible new accounts can use this [Vultr referral link](https://www.vultr.com/?ref=9921378-9J)
to claim **$300 in trial credit**, enough for roughly a month of this small
server's compute within the trial period. A valid credit card or PayPal method
is required; duplicate accounts are excluded, unused credit expires after
30 days, and the offer is subject to Vultr's current terms. The maintainer may
receive a referral payment for qualifying signups.

The expiry date matters more than the amount. A `$5/month` server will not use
up `$300` in a month, but the unused credit still expires. The server does not
then stop billing. [Destroy it when finished](docs/05-testing-and-teardown.md#teardown);
shutting it down is not enough.

## Working on the scripts

The regression tests use fake API responses and temporary files. They do not
need a Vultr account or create cloud resources.

```bash
python3 -m unittest discover -s tests -v
shellcheck -x scripts/*.sh scripts/lib/*.sh
```

[CI](.github/workflows/ci.yml) also scans Git history for secrets.

MIT license. See [LICENSE](LICENSE).
