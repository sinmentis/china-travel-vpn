# Set it up with the script

**English** · [中文](quickstart.zh-CN.md)

The script handles the server. You still need a Vultr account, an API key, and
a client on your phone. It does not sign up for accounts or configure the
phone for you.

## 1. Use a Linux terminal

Use Ubuntu 24.04 locally, in a VM, or under
[WSL](https://learn.microsoft.com/windows/wsl/install) on Windows.
The script downloads a Linux test client, so native PowerShell and macOS are
not supported script environments.

Install the local tools, then clone the repository:

```bash
sudo apt update
sudo apt install -y git curl python3 openssh-client openssl coreutils tar qrencode
git clone https://github.com/sinmentis/china-travel-vpn.git
cd china-travel-vpn
```

Already cloned it? Use that checkout rather than creating another.

## 2. Allow this machine to use the Vultr API

Create a Vultr account and add a payment method if needed. There is an optional
[referral link and trial offer](../README.md#trial-credit).

In **Account → API**, enable API access and copy the API key. Under
**Access Control**, allow this machine's public IPv4 with `/32`. Find it here:

```bash
curl -4fsS https://api.ipify.org
printf '\n'
```

If you are SSH'd into a VM, run that command in the VM. Its address needs to
be allowed, not your laptop's. Do not use `0.0.0.0/0`.

## 3. Run the script

```bash
./scripts/bring-up.sh
```

On a fresh checkout it asks for the API key and a REALITY target hostname.
The target is a public HTTPS site used for camouflage, not a domain you own.
Choose one that passes [the target checks](03-vless-reality.md#target).
Enter only its hostname, without `https://` or a path.

The default is Osaka, Ubuntu 24.04, and `vc2-1c-1gb`. The script installs Xray,
reboots the server, and checks an authenticated connection. Wait for `READY`.
An error can leave a billable instance behind; check Vultr before walking away.

An existing instance with the configured label is reused. This command is not
an IP rotation button, and rerunning the full setup can briefly interrupt it.

## 4. Import the result

The files are in the checkout where you ran the script:

| File | Use |
|---|---|
| `primary-ios.local.txt` | VLESS import link |
| `primary-ios.local.png` | QR code, generated when `qrencode` is installed |
| `.env.vultr` | API key, SSH key passphrase, and server credentials |

Follow [client setup](04-client-setup.md). Treat the link and QR code as
passwords. The files are Git-ignored, not encrypted; back up `.env.vultr` and
`~/.ssh/travel_ed25519` securely.

## Checking it later

```bash
./scripts/bring-up.sh --verify-only
```

This skips installation, configuration, and reboot, but refreshes local records
and import files. It can also upload a missing SSH public key or start a stopped
instance; it is not a strictly read-only command.

When finished, use [teardown](05-testing-and-teardown.md#teardown).
