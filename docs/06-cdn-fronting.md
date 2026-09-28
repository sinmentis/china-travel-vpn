# Hiding behind a CDN

**English** · [中文](06-cdn-fronting.zh-CN.md)

REALITY protects the *protocol*. It does nothing for the *address*. Once your
server's IP lands on a blocklist, a perfect handshake is irrelevant — the
packets never arrive. That is the failure this page is for.

The fix is to stop handing out your server's address. Traffic goes to
Cloudflare instead, and Cloudflare forwards it to your server. Blocking that
means blocking addresses shared with a large part of the web, which is a much
more expensive thing to do.

You pay for it in speed. Every packet takes an extra hop, and the CDN adds its
own TLS termination. Expect it to be noticeably slower than a direct
connection. Use REALITY while it works, and keep this as the thing you switch
to when it stops.

| | REALITY (default) | CDN fronting |
|---|---|---|
| Speed | Fast, one hop | Slower, extra hop |
| Survives an IP block | No | Yes |
| Needs a domain | No | Yes |
| Origin address exposed | Yes | No |

## What you need first

A domain on Cloudflare. Any registrar works, but the nameservers have to point
at Cloudflare so it can proxy the traffic. The free plan is enough. If you do
not already have a domain this is the one real cost of this route, and it is
usually a few dollars a year.

Pick a hostname to use. It can be the bare domain or anything under it —
`edge.example.com` is fine, and a boring name is better than a clever one.

Then create an API token at **Manage Account → API Tokens → Create Token**,
using **Create Custom Token**. It needs three permissions:

| Permission | Why |
|---|---|
| Zone → Zone → Read | Find the zone that owns your hostname |
| Zone → DNS → Edit | Point the hostname at the server |
| Zone → SSL and Certificates → Edit | Issue the origin certificate |

Under **Zone Resources**, restrict it to the one zone you are using. Copy the
token once; Cloudflare will not show it again.

One setting has to be right or nothing works. In **SSL/TLS → Overview**, the
encryption mode must be **Full** or **Full (strict)**. On **Flexible**,
Cloudflare talks plain HTTP to your server, your server answers in TLS, and
the connection dies with no useful error.

## Deploying it

```bash
TRANSPORT=cdn ./scripts/bring-up.sh
```

The script asks for the hostname and the API token, saves both, and from then
on the setting lives in `.env.vultr`. Later runs do not need the variable:

```bash
./scripts/bring-up.sh --verify-only
```

Behind that one command, the script:

1. Finds the Cloudflare zone that owns your hostname, walking up the domain
   until it matches. A hostname on a domain you have not added to Cloudflare
   fails here, before anything is created.
2. Creates the server and hardens it as usual.
3. Adds a **proxied** `A` record for your hostname. Proxied is the whole point;
   an unproxied record would publish the very address you are hiding.
4. Generates a private key **on the server**, sends only the signing request to
   Cloudflare, and installs the certificate that comes back. The private key
   never leaves the machine.
5. Configures Xray for VLESS over WebSocket with TLS.
6. Restricts port `443` to Cloudflare's own address ranges.
7. Runs a real authenticated request through Cloudflare and checks the exit IP.

Step 6 is worth a sentence. Because the origin only ever talks to Cloudflare,
there is no reason to accept anyone else. Anybody scanning your server's
address finds a closed port instead of a TLS service to fingerprint. The ranges
are fetched at deploy time; if Cloudflare ever adds new ones, rerun the script.

The certificate is a [Cloudflare origin certificate](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/).
Only Cloudflare trusts it, which is all that is needed here — visitors see
Cloudflare's own public certificate. It is valid for 15 years, so there is no
renewal to forget about.

## The manual version

If you would rather configure it yourself, the inbound looks like this. The
path is a shared secret: anything that does not match it is not your traffic.

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

Note what is missing: no `flow`. Vision needs a raw TCP stream, and a
WebSocket is not one. Setting it anyway breaks the connection.

Generate the key and request the certificate like this, replacing the
hostname:

```bash
sudo install -d -m 750 /usr/local/etc/xray/tls
sudo openssl ecparam -genkey -name prime256v1 \
  -out /usr/local/etc/xray/tls/origin.key
sudo openssl req -new -key /usr/local/etc/xray/tls/origin.key \
  -subj "/CN=edge.example.com" -outform PEM
```

Paste that request into **SSL/TLS → Origin Server → Create Certificate**, then
save the signed result to `/usr/local/etc/xray/tls/origin.crt`. Both files
should be owned by `root`, readable by the Xray service group, and mode `640`.

## Checking it

The client link is written to `primary-ios.local.txt` as usual, and points at
your hostname rather than an IP address. Import it the same way as the
[REALITY link](04-client-setup.md).

To confirm Cloudflare is actually in front of the server, look up the hostname.
The address you get back belongs to Cloudflare, not to your server:

```bash
dig +short edge.example.com
```

If that returns your server's real address, the record is not proxied. Fix it
in the Cloudflare dashboard before using the tunnel.

## Things that behave differently

Idle WebSocket connections are closed after about 100 seconds on the free
plan. Clients reconnect on their own, so this shows up as a brief pause rather
than a failure.

Teardown also releases the Cloudflare resources. `bring-down.sh` removes the
DNS record and revokes the origin certificate, because a record left pointing
at a recycled address is somebody else's problem later.

If the tunnel stops working on this route, the address is no longer the likely
cause. Start with [troubleshooting](../TROUBLESHOOTING.md) instead of replacing
the server.

Next: [client setup](04-client-setup.md).
