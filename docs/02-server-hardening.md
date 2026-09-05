# 02 - Set up SSH and the firewall

**English** · [中文](02-server-hardening.zh-CN.md)

The useful rule here is simple: prove a new SSH login works before closing
the old one. An existing session staying connected does not prove you can get
back in.

Continue from [the server page](01-prerequisites-and-servers.md).
Replace `SERVER_IP`, then log in as `root`:

```bash
ssh -i ~/.ssh/travel_ed25519 root@SERVER_IP
```

## 9. Update the system and sync the clock `[SERVER]`

```bash
apt update
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt upgrade -y
timedatectl set-timezone UTC
timedatectl set-ntp true

for _ in $(seq 1 30); do
  [ "$(timedatectl show -p NTPSynchronized --value)" = yes ] && break
  sleep 2
done

timedatectl
```

Look for `System clock synchronized: yes` and `NTP service: active`.
The loop gives time synchronization a minute to settle.

## 10. Add an account for administration `[SERVER]`

`ops` will log in with the same SSH key and use passwordless `sudo`.
Keep that key private; it gives full control of the server.

```bash
id ops >/dev/null 2>&1 || adduser --disabled-password --gecos "" ops
install -d -m 700 -o ops -g ops /home/ops/.ssh
install -m 600 -o ops -g ops /root/.ssh/authorized_keys /home/ops/.ssh/authorized_keys
usermod -aG sudo ops
echo 'ops ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ops
chmod 440 /etc/sudoers.d/ops
visudo -cf /etc/sudoers.d/ops
```

In a new terminal on your computer, try the new account:

```bash
ssh -i ~/.ssh/travel_ed25519 ops@SERVER_IP 'sudo whoami'
```

It should print `root`. Leave the original root session open.

## 11. Turn off password login `[SERVER]`

Back in that root session, write a small SSH configuration file:

```bash
cat > /etc/ssh/sshd_config.d/00-personal-vpn.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF

chmod 644 /etc/ssh/sshd_config.d/00-personal-vpn.conf
sshd -t && systemctl restart ssh
sshd -T | grep -E '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin)'
```

The output should include `permitrootlogin without-password`,
`passwordauthentication no`, and `kbdinteractiveauthentication no`.
Open another fresh `ops` connection with the command from step 10.
Only close the original session once that succeeds.

## 12. Load the firewall rules `[SERVER]`

This replaces the server's firewall rules. It is for the fresh, dedicated
machine from step 6, not a shared host.

```bash
apt install -y nftables
command -v ufw >/dev/null 2>&1 && ufw --force disable

cat > /etc/nftables.conf <<'EOF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;

    ct state established,related accept
    ct state invalid drop
    iif lo accept

    tcp dport 22 accept
    tcp dport { 80, 443 } accept
    udp dport 443 accept

    ip protocol icmp icmp type { echo-request, destination-unreachable, time-exceeded } accept
    ip6 nexthdr icmpv6 accept
  }

  chain forward { type filter hook forward priority 0; policy drop; }
  chain output  { type filter hook output  priority 0; policy accept; }
}
EOF

nft -c -f /etc/nftables.conf
systemctl enable --now nftables
nft -f /etc/nftables.conf
nft list ruleset | grep -E 'policy drop|dport'
```

The input chain should show `policy drop`, with TCP `22`, `80`, `443` and
UDP `443` allowed. The rules match the deployment script.

## 13. Keep this setup IPv4-only `[SERVER]`

```bash
cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl --system
ip -6 addr show scope global
```

The last command should print nothing. Reboot to check that the settings survive:

```bash
reboot
```

Wait about a minute and reconnect as `root`. If you use `ops`, run `sudo -i`
before the following commands:

```bash
for _ in $(seq 1 30); do
  [ "$(timedatectl show -p NTPSynchronized --value)" = yes ] && break
  sleep 2
done

printf 'nftables='; systemctl is-active nftables
printf 'drop_policies='; nft list ruleset | grep -c 'policy drop'
printf 'global_ipv6='; ip -6 addr show scope global | grep -c inet6 || true
printf 'clock='; timedatectl show -p NTPSynchronized --value
```

You want `nftables=active`, `drop_policies=2`, `global_ipv6=0`, and `clock=yes`.
If one differs, check [the server state](../TROUBLESHOOTING.md#server-state)
before installing the proxy.

Next: [Xray and REALITY](03-vless-reality.md).
