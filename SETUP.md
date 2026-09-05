# Setup

**English** · [中文](SETUP.zh-CN.md)

There are two ways through this. The [script setup](docs/quickstart.md) does the
server work for you. The pages below show the commands if you want to do it by
hand. Pick one; there is no need to run both.

The target is a fresh Ubuntu 24.04 server on Vultr. Do not paste the firewall
or SSH changes into a machine that already hosts something you care about.

## Manual path

| Steps | Page | Done when |
|---|---|---|
| 1–8 | [Account and server](docs/01-prerequisites-and-servers.md) | You can log in over SSH |
| 9–13 | [SSH and firewall](docs/02-server-hardening.md) | A new login works after reboot |
| 14–19 | [Xray and REALITY](docs/03-vless-reality.md) | Xray runs and the camouflage target answers |
| 20–25 | [Client](docs/04-client-setup.md) | Your phone or computer uses the server's exit IP |
| 26–28 | [Before and after the trip](docs/05-testing-and-teardown.md) | You know how to check, replace, and destroy it |

`[LOCAL]` means the computer you are working from. Bash blocks need a Linux
shell; Windows users can use Ubuntu under
[WSL](https://learn.microsoft.com/windows/wsl/install), the Windows Subsystem
for Linux. Native PowerShell commands are marked separately.

`[SERVER]` means the remote Vultr machine. Run those commands as `root`.
If you logged in as `ops`, run `sudo -i` first.

`SERVER_IP` in the manual is a placeholder for your server's public IPv4.
The automation saves that same address as `PRIMARY_IP` in `.env.vultr`.
Keep the credentials worksheet from the first page in your password manager.

Each page ends with the next step. If a command gives an unexpected result,
use [troubleshooting](TROUBLESHOOTING.md) before continuing.
The reasons behind the settings live in [the technical notes](RESEARCH.md),
not between every two commands.
