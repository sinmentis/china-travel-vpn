# 04 - Connect a client

**English** · [中文](04-client-setup.zh-CN.md)

Use one app on each device. You do not need a second app to finish this setup.
The phone still needs its own check even if the server-side tests passed.

## 20. Have the connection details ready

If you ran the script, use `primary-ios.local.txt` or `primary-ios.local.png`
from the checkout. Despite the filenames, the text is a VLESS link that other
compatible clients can import too.

If you followed the [manual setup](03-vless-reality.md), use your worksheet:

| Field | Value |
|---|---|
| Protocol | VLESS |
| Address | `SERVER_IP` |
| Port | `443` |
| UUID / ID | `VPN_UUID` |
| Flow | `xtls-rprx-vision` |
| Transport | TCP |
| TLS security | REALITY |
| SNI / server name | `REALITY_TARGET` |
| Public key / `pbk` | `REALITY_PUBLIC_KEY` |
| Short ID / `sid` | `REALITY_SHORT_ID` |
| Fingerprint | `chrome` |

SNI is the hostname sent during the TLS handshake. Use the target hostname,
not the server IP. The public key is the value Xray labels
`Password (PublicKey)`, not `Hash32`.

## 21. Windows

Install [v2rayN](https://github.com/2dust/v2rayN). Import the VLESS link from
the clipboard, or add a VLESS server with the fields above.
Select it and enable the system proxy.

The system proxy only covers applications that use it. It is not a promise
that every process on the computer now goes through the tunnel.

## 22. Android

A client such as husi can import the VLESS link. Add it, select the server,
and approve Android's VPN permission.

If you choose the official sing-box app instead, it expects a complete
sing-box JSON configuration. The generated VLESS link is not that format.
Keep the installer APK somewhere accessible before travelling.

## 23. iPhone

1. Install [Streisand](https://apps.apple.com/app/streisand/id6450534064).
2. Tap `+` and scan the QR code or import the copied link.
3. Connect and approve the iOS VPN permission.

For a manual deployment, enter the fields from step 20 instead.
If the script ran on a remote computer, transfer the import file privately;
do not upload it to a public QR-code service.

Open `https://api.ipify.org` in the phone's browser. The IP should match the
server's public IPv4. Repeat on Wi-Fi and cellular. Geolocation databases can
disagree about the city, so compare the address rather than the map label.
Install the app before travelling; App Store availability depends on region.

## 24. Route domestic services directly

Split tunnelling means choosing which traffic uses the proxy. The import link
contains the server details, **not** a complete set of routing or DNS rules.

In the client's routing settings, send reachable domestic services directly.
Start with a domain you use, then check the client's log to confirm the route.
Client menus differ; this repository does not supply a universal China-rule
profile for every app.

## 25. Save the working configuration

Keep the link or exported profile in your password manager.
It contains credentials; a QR image is not a safer form of the same data.

Next: [checks and teardown](05-testing-and-teardown.md).
