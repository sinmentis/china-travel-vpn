# Notes from building this

**English** · [中文](RESEARCH.zh-CN.md)

The useful findings were not a ranking of cloud providers. They were smaller:
a configuration check can pass as the wrong user, a convincing TLS response
can come from the wrong connection path, and a fast server can still give a
phone a slow connection.

These technical observations were recorded on 2026-09-04. They do not include
long-term results or measurements from Chinese residential or mobile networks.

## Why stop at one server?

The project supports a single-user proxy, not a hosted service for multiple
users. One Vultr instance keeps the deployment and recovery procedures small.
It also leaves a single point of failure. Both statements matter.

The recorded plan, `vc2-1c-1gb` in Osaka, costs about `$0.007/hour`.
For example, `504` hours costs roughly `$3.53` of compute before taxes and extras.
Hourly billing makes a short-lived replacement inexpensive. It does not
guarantee that the next IP will work from a particular network.

Osaka is the location used here, not the winner of a controlled comparison
across every region. There is no evidence in these tests for calling it
"the best China route."

<a id="protocol"></a>

## What REALITY removes, and what it does not

Xray is the server program. VLESS is the proxy protocol; Vision is its flow
mode. REALITY handles the TLS camouflage and authentication used by this setup.

One practical benefit is that there is no domain to register and no public
certificate to renew on this server. Connections without valid REALITY
authentication can be forwarded to a real HTTPS target. A probe can therefore
receive that site's genuine certificate and content.

This is not the same as making every packet indistinguishable from a browser,
and it does not hide the server's IP. Changing a protocol's port to `443` does
not make it HTTPS, either. This configuration uses Xray's supported REALITY
path directly on `443`, with no front-end reverse proxy to introduce another
variable. Port `80` forwards to the same target.

The [upstream REALITY documentation](https://github.com/XTLS/REALITY) describes
the design. The [manual configuration](docs/03-vless-reality.md) is the concrete
version used here.

<a id="service-user"></a>

## `root` can read it. Xray might not.

The first manual procedure set the Xray configuration to `root:root 600`.
That sounds reasonable for a file containing a private key.
Checking the installed service exposed the missing detail: it runs as `nobody`.

On the server:

```bash
systemctl show xray -p User -p Group
sudo -u nobody xray run -test -c /usr/local/etc/xray/config.json
```

A config test run as `root` answers whether root can read and parse the file.
It says nothing about the service account. For the pinned installer's
`nobody`/`nogroup` setup, the file is now `root:nogroup 640`. The automated
script looks up the service user and group instead of assuming root.

The same idea applies to SSH. A session left open across a configuration change
is not proof that the next login will succeed. Test a new connection before
discarding the old one.

<a id="reality-version"></a>

## A valid certificate can be the wrong success signal

A plain `curl` request to the server does not contain REALITY credentials.
Getting the target site's certificate and HTTP `200` is evidence that the
camouflage path works. It does not prove that your proxy client authenticated.

That distinction matters for `minClientVer`. Xray `v26.7.28` reports this
default when the field is omitted:

```text
[Warning] infra/conf: REALITY: The default minimal client version is
Xray-core v26.3.27, other clients may be refused to connect
```

In [sing-box v1.14.0's REALITY client](https://github.com/SagerNet/sing-box/blob/v1.14.0/common/tls/reality_client.go#L186-L188),
the advertised version is assigned explicitly:

```go
hello.SessionId[0] = 1
hello.SessionId[1] = 8
hello.SessionId[2] = 1
```

That is `1.8.1`, not the sing-box release number. The server config therefore
sets `minClientVer` to `1.8.1` for this client's compatibility. An authenticated
request through this combination returned the Vultr server's exit IP.

There is a cost. Xray also prints:

```text
[Warning] infra/conf: REALITY: Changing "minClientVer" will increase the
likelihood of your server's IP being blocked by the GFW
```

This is a compatibility decision, not a trick that makes the default safer.
Do not lower the value further just because a connection failed. If every
client uses a compatible Xray core, the stricter default may be appropriate.
The client implementation matters here, not its operating system.
Future releases need another check.

One other naming detail from the pinned Xray version: the public key for the
client's `pbk` field is labelled `Password (PublicKey)`, not `Hash32`.

```text
PrivateKey: <server-private-key>
Password (PublicKey): <client-public-key>
Hash32: <other-derived-value>
```

<a id="performance"></a>

## More RAM is not a shorter network path

An early phone measurement over cellular was about `32 Mbps`. Before choosing
a larger server, downloads from the Cloudflare speed endpoint were compared:

| Path | Observed download rate |
|---|---:|
| Vultr server directly | `2181.1 Mbps` |
| Azure VM directly | `2061.3 Mbps` |
| The same Azure VM through REALITY on Vultr | `152.8 Mbps` |

These were `50 MB` downloads, not a long-running capacity test. They also used
a different client and network from the phone. They show that the setup is not
fixed at `32 Mbps`; they do not identify the phone's bottleneck.

During a later sequence of downloads through the tunnel, Xray's sampled CPU
usage averaged `0.6%`, with a `2%` peak. The server already used BBR, a TCP
congestion-control algorithm, with the `fq` queue discipline. Neither result
gave a reason to add CPU or RAM at that point.

The next useful comparison is on the phone itself: same network, same test,
VPN on and off, then repeat on Wi-Fi. Buying a larger instance before that
would be changing a variable without evidence that it matters.

## A routing graph is not a transit contract

RIPEstat's [ASN-neighbours data](https://stat.ripe.net/data/asn-neighbours/data.json?resource=AS20473)
was used to examine the surrounding networks. An ASN is a routing network's
identifier; Vultr's network is associated with `AS20473`. BGP, the protocol
that exchanges routes between networks, provides useful topology clues.

But visible adjacency does not tell us what a provider has purchased, nor
does its absence prove that a particular transit service is unavailable.
It also does not reveal the path a Chinese carrier will choose for the return
traffic.

So that data is useful for investigation, not enough for a blanket claim that
"no mainstream provider buys premium routes." A test from the actual access
network is more relevant than a confident conclusion from an incomplete graph.

<a id="versions"></a>

## Pin the inputs, not the conclusion

The automated setup uses these versions:

| Component | Pin |
|---|---|
| Xray-core | [`v26.7.28`](https://github.com/XTLS/Xray-core/releases/tag/v26.7.28) |
| sing-box test client | [`v1.14.0`](https://github.com/SagerNet/sing-box/releases/tag/v1.14.0) |
| Xray installer | [`e741a4f`](https://github.com/XTLS/Xray-install/tree/e741a4f56d368afbb9e5be3361b40c4552d3710d) |

The script checks the installer against a fixed SHA-256 hash. The Xray installer
checks the release archive, and the sing-box download is compared with the
release asset's published digest. These are checksum checks, not cryptographic
signatures, and they still depend on the integrity of their sources.

Pinning makes a result reproducible. It does not make a version permanently
safe or compatible with every later client. The current config uses `raw` and
`target`; old examples may call those fields `tcp` and `dest`. Copy a complete
configuration for the intended version rather than mixing snippets.

## The expiry date is the part of the trial worth watching

The account API exposed the credit as a negative balance. The guard computes
remaining credit as `max(0, -balance - pending_charges)`. That amount does not
tell it when promotional credit expires; the deadline has to be supplied.

[Stopped Vultr instances still bill](https://docs.vultr.com/support/platform/billing/are-stopped-instances-still-billed-on-vultr).
The [guard script](scripts/vultr-credit-guard.sh) requests deletion when its
threshold or deadline is reached. It is an external precaution, not a hard
spending cap. Its host, credentials, and API access all have to keep working.

What remains unmeasured is straightforward: performance and reachability from
mainland China, across the intended networks and times of day. The setup
does not get to claim those results just because the deployment finished.
