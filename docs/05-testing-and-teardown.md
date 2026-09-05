# 05 - Check it, then stop paying for it

**English** · [中文](05-testing-and-teardown.zh-CN.md)

Getting a VPN icon on the phone is not the finish line. First check that the
traffic goes where you intended. Later, remember to delete the billable server.

## 26. Before leaving

- [ ] The server has rebooted and both `xray` and `nftables` are running.
- [ ] The [camouflage check](03-vless-reality.md#camouflage) still passes.
- [ ] The client opens a site through the tunnel and shows the server's exit IP.
- [ ] It works on the networks you expect to use, including Wi-Fi and cellular.
- [ ] Domestic direct-routing rules and DNS behaviour match the client settings.
- [ ] The working client profile and SSH key are backed up.

The full bring-up script already performs the server reboot and its own client
test. You do not need another reboot just to tick a box.
These checks outside China still do not establish performance inside China.

## 27. Know the replacement procedure

You do not have to delete a working server as a setup ritual.
If you want to practise replacing one, follow
[the replacement steps](../TROUBLESHOOTING.md#replace-server).
They create the replacement before deleting the old instance.

Keep the distinction clear: `bring-up.sh` reuses an instance with the configured
label. Running it again is not the same as getting a new IP.

<a id="teardown"></a>

## 28. When finished

For a scripted deployment, run these commands from the original checkout.
First inspect the target:

```bash
./scripts/bring-down.sh --dry-run
```

Check the label and IP. When you are ready to permanently delete that instance:

```bash
./scripts/bring-down.sh --yes
```

For a manual deployment, use **Destroy** in Vultr.
Confirm the instance is gone and check the billing page for other resources.
Deletion ends that instance's future charges; it does not erase charges already
incurred or delete separately billed storage and snapshots.

The teardown script keeps reusable SSH and REALITY credentials. Revoke the API
key when you no longer need automation.

## Trial credit needs a deadline

A stopped Vultr instance still bills. Expiring credit does not turn the account
into a prepaid service, either. Arrange teardown at least a day before the
displayed expiry date; if no timezone is given, leave extra margin.

The [credit guard](../scripts/vultr-credit-guard.sh) checks remaining credit
against `CREDIT_GUARD_MIN_REMAINING` (default `$1`) and a required UTC
`CREDIT_GUARD_DEADLINE`. It only targets instance labels beginning with the
configured `personal-vpn-` prefix. It does not manage other billable resources.

The script makes one check per run. Daily scheduling requires a separate
systemd timer or cron job on a machine that stays online; `bring-up.sh` does
not install that schedule. API access must keep working. Use
`CREDIT_GUARD_DRY_RUN=1` when trying the guard, and treat it as a precaution,
not a provider-enforced spending cap.
