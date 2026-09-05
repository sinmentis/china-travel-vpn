# China Travel VPN

**English** · [中文](README.zh-CN.md)

One small Vultr server in Osaka, 1 GB of memory, and Xray running VLESS +
Vision + REALITY on TCP `443`. This repository contains the setup, client
configuration, and teardown instructions. There is no management panel and
no domain to buy.

One server also means one point of failure. If it stops working, there is no
second endpoint waiting to take over. That is the trade-off here: fewer things
to maintain, in exchange for accepting downtime while fixing the connection.

## What has actually worked

The documented checks cover deployment, reboot recovery, and authenticated
connections with sing-box and Streisand. They do not establish performance on
mainland Chinese access networks, at peak hours, or over extended use.
REALITY reduces some differences between the tunnel and ordinary TLS traffic;
it does not make the server unblockable.

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

Prefer to run the commands yourself? The [manual setup](SETUP.md) has five
short pages. If the server is already running, go straight to
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
