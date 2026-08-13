# The chrony service

`service/chrony` belongs in `/etc/dinit.d/`, and a symlink to it in
`/etc/dinit.d/boot.d/`. It is not installed by this package: `veron-system`
owns `/etc/dinit.d` entirely, and two packages writing into one directory is
the thing that goes wrong silently.

It is shipped here rather than in `veron-system` so the service and the daemon
it starts stay together, and so this directory is the whole of what chrony
adds.

## What still has to happen in veron-system

**The `_chrony` user and group.** `--with-user=_chrony` means chronyd drops to
it after binding, and if the account does not exist chronyd exits at startup.
`dhcpcd`'s own recipe records the same trap for `_dhcpcd`, and calls it the
part that fails silently.

```
_chrony:x:53:53:chrony:/var/lib/chrony:/bin/false
```

**`/var/lib/chrony`, owned by `_chrony`.** The drift file and the NTS key cache
live there. Without it chronyd starts, works, and relearns the oscillator's
drift from scratch on every boot.
