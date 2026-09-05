# 01 - Get a server

**English** · [中文](01-prerequisites-and-servers.zh-CN.md)

This is the manual route. If you used [the script](quickstart.md), skip to
[the client](04-client-setup.md).

## 1. Have these ready `[LOCAL]`

You need a payment method Vultr accepts, an authenticator app, a password
manager, and an SSH client. No domain purchase is needed.
Use the [environment notes](../SETUP.md) if the terminal commands are unfamiliar.

## 2. Create the account `[LOCAL]`

1. Register on [Vultr](https://www.vultr.com/) with accurate account details.
2. Add a payment method.
3. Enable authenticator-based two-factor authentication and save the recovery codes.

The optional [referral offer](../README.md#trial-credit) has its own eligibility
and expiry rules. Manual setup does not require an API key.

## 3. Keep access to the control panel `[LOCAL]`

Bookmark the Vultr dashboard. After creating the instance in step 6, open
**View Console** once. This gives you another way into the machine if SSH fails.

If you plan to rely on home-SIM roaming to reach the dashboard during the trip,
check that it is enabled and what it costs. It is an access option, not a
guaranteed recovery path.

## 4. Generate an SSH key `[LOCAL]`

If `~/.ssh/travel_ed25519` already exists, reuse it; do not overwrite it.
Otherwise run:

```bash
ssh-keygen -t ed25519 -C "travel-2026" -f ~/.ssh/travel_ed25519
```

Set a passphrase. Back up the private key in your password manager.

## 5. Upload the public half `[LOCAL]`

Copy `~/.ssh/travel_ed25519.pub` into Vultr's **SSH Keys** page.
The file without `.pub` stays on your computer.

## 6. Create the instance `[LOCAL]`

Choose **Cloud Compute → Shared CPU** and use these settings:

| Setting | Value |
|---|---|
| Region | Osaka (`itm`) |
| OS | Ubuntu 24.04 LTS x64 |
| Plan | `vc2-1c-1gb` |
| Label | `personal-vpn-primary` |
| SSH key | The key from step 5 |
| IPv6, backups, paid extras | Off |

The recorded compute price is `$5/month`, billed hourly at about `$0.007/hour`.
Check the current quote before creating it. The scripts still use the
`personal-vpn-` label prefix; do not rename it just to match the repository.

## 7. Keep a small worksheet `[LOCAL]`

Put this in your password manager. The remaining values come from
[the Xray page](03-vless-reality.md).

```text
SERVER_IP            = <public IPv4 from Vultr>
REALITY_TARGET       = <step 14>
VPN_UUID             = <step 16>
REALITY_PUBLIC_KEY   = <step 16>
REALITY_SHORT_ID     = <step 16>
```

## 8. Log in once `[LOCAL]`

Replace `SERVER_IP` below with the actual IPv4:

```bash
ssh -i ~/.ssh/travel_ed25519 root@SERVER_IP 'echo OK; uname -m'
```

You should see `OK` and `x86_64`. If not, sort out SSH before going further.

Next: [SSH and firewall](02-server-hardening.md).
