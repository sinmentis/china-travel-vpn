# 02 - 配好 SSH 和防火墙

[English](02-server-hardening.md) · **中文**

这里最管用的一条规矩：新连接能登录，再关旧连接。
原来的会话没断，不代表下次还登得进去。

接着[上一页](01-prerequisites-and-servers.zh-CN.md)做。
把 `SERVER_IP` 换好，以 `root` 登录：

```bash
ssh -i ~/.ssh/travel_ed25519 root@SERVER_IP
```

## 9. 更新系统，把时间对上 `[SERVER]`

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

看输出中有没有 `System clock synchronized: yes` 和 `NTP service: active`。
循环会留出一分钟，等时间同步完成。

## 10. 加一个日常管理账号 `[SERVER]`

`ops` 用同一把 SSH 密钥登录，可以免密码执行 `sudo`。
这把密钥能控制整台机器，要保管好。

```bash
id ops >/dev/null 2>&1 || adduser --disabled-password --gecos "" ops
install -d -m 700 -o ops -g ops /home/ops/.ssh
install -m 600 -o ops -g ops /root/.ssh/authorized_keys /home/ops/.ssh/authorized_keys
usermod -aG sudo ops
echo 'ops ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ops
chmod 440 /etc/sudoers.d/ops
visudo -cf /etc/sudoers.d/ops
```

在自己电脑上新开一个终端，试试新账号：

```bash
ssh -i ~/.ssh/travel_ed25519 ops@SERVER_IP 'sudo whoami'
```

应该输出 `root`。原来的 root 会话先别关。

## 11. 关闭密码登录 `[SERVER]`

回到 root 会话，写一份小配置：

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

输出应包含 `permitrootlogin without-password`、`passwordauthentication no`
和 `kbdinteractiveauthentication no`。
再用第 10 步的命令新建一条 `ops` 连接，成功后才能关原来的会话。

## 12. 加载防火墙规则 `[SERVER]`

这段会替换服务器的防火墙规则，只用于第 6 步新开的专用机器，不要在共享主机上执行。

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

input 链应显示 `policy drop`，放行 TCP `22`、`80`、`443` 和 UDP `443`。
这里与部署脚本使用同一组规则。

## 13. 这套配置先只走 IPv4 `[SERVER]`

```bash
cat > /etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
EOF
sysctl --system
ip -6 addr show scope global
```

最后一条命令应该没有输出。重启一次，看设置是否还在：

```bash
reboot
```

等大约一分钟，以 `root` 重新连接。如果用的是 `ops`，先 `sudo -i` 再执行：

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

应该得到 `nftables=active`、`drop_policies=2`、`global_ipv6=0` 和 `clock=yes`。
有一项不对，先查[服务器状态](../TROUBLESHOOTING.zh-CN.md#server-state)，再装代理。

下一页：[Xray 与 REALITY](03-vless-reality.zh-CN.md)。
