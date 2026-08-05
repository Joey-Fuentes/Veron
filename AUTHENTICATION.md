# Authentication

What this system does about logging in, and why. Two research reports informed
it; both are kept verbatim under `research/` and are point-in-time — the Linux
passkey landscape is moving, and where a finding has a date it is because that
date matters.

---

## Where it stands today

**Autologin root on the console, no password anywhere.** `veron-system` ships
`/etc/passwd` with root and nobody, no `/etc/shadow`, and a dinit service that
runs `busybox getty -n -l /bin/sh` on `ttyAMA0`.

**That is defensible, and only for one reason: there is no network.** No
sshd, nothing listening, `-nic none` in the boot test. Console access means
you already have the machine — the posture of a live ISO.

**The trigger, not the state, is what matters.** The day networking lands that
sentence stops being true. This is recorded as a condition rather than left as
an assumption someone later mistakes for a decision.

---

## Decided: PAM-free

`STAGE5.md` used to say *"No PAM, if there is no display manager. If SDDM
lands, PAM likely follows."* That was a guess. It is now a decision, with a
reason.

**PAM buys a config-file abstraction, not security, on a single-admin box** —
and it costs more than its own tail. libpam itself is modest (libaudit,
libxcrypt, optionally libcap), but **busybox's `login` and `su` applets are not
PAM-aware and bypass it entirely**. Going PAM therefore means also adopting
shadow or util-linux for a PAM-aware login — precisely the dependency tails
this project declines everywhere else.

| | new packages |
|---|---|
| **PAM-free** (chosen) | libcbor, libfido2, an SSH server, + an in-house login helper |
| PAM | linux-pam, pam_u2f, libcbor, libfido2, libxcrypt, libaudit, **+ shadow or util-linux** |

The PAM-free path is roughly half the packages and none of the large ones.

---

## The three surfaces

### Console

A small `veron-login` helper linking libfido2 directly: read the registered
credential id and public key, generate a random challenge, `fido_dev_get_assert()`,
`fido_assert_verify()`, then `setuid` and exec. That is the WebAuthn assertion
ceremony without the browser or RP layer.

**busybox `login` has no hook for alternative authentication**, so the helper
replaces it rather than plugging into it — dinit runs
`getty -n -l /usr/bin/veron-login` instead of `-l /bin/sh`.

### SSH

**The server needs no FIDO2 code at all.** OpenSSH 8.2 (2020-02-14) added the
`ecdsa-sk` and `ed25519-sk` key types, and all hardware interaction is on the
**client** side through a middleware library. A server storing an
`sk-ssh-ed25519@openssh.com` key in `authorized_keys` verifies a signature and
nothing more — no libfido2, no USB, no PAM.

If Veron is also an SSH *client* using a hardware key, that build needs
`--with-security-key-builtin` and libfido2.

**Dropbear is a legitimate smaller alternative** — server-side sk-key support
landed in Dropbear 2022.82 (2022-04-01) behind `DROPBEAR_SK_KEYS`, and like
OpenSSH it needs no libfido2 to *verify*.

### Browser

**WebKit has no WebAuthn on Linux, and this is the one genuinely blocked
surface.** `ENABLE_WEB_AUTHN` is `PRIVATE OFF` in
`Source/cmake/WebKitFeatures.cmake` and not overridden by the WPE or GTK port
options; the only in-tree transport backend is macOS/IOKit. WebKit Bugzilla
#205350 has been open since 2019.

**Implementing it is ours, and it is bounded.** WebKit's CTAP1/CTAP2, CBOR, HID
framing and PIN protocol are all platform-independent C++ already in the tree.
A Linux backend supplies **device I/O only** — enumerate `/dev/hidraw*`, filter
on FIDO usage page `0xF1D0`, read and write reports. Roughly 1,000–2,000 lines
across a handful of new files.

**No new dependencies.** hidraw is a kernel interface; libudev-zero is already
in the set.

**It is part of a commitment already made.** `STAGE5.md` states the browser
shell does not exist and is ours to write. This is more of that work, not a new
undertaking — with the one difference worth naming: the transport is a patch
against WebKit's tree and rebases every release, where the shell is ours and
does not.

**Upstream will not take it**, and the reason does not apply here: WebKit wants
a D-Bus portal so passkeys work under Flatpak. Veron has no Flatpak. So this is
a carried downstream patch, permanently.

---

## What is blocked, and on what

**Any password, for anyone.** `crypt()` comes from libxcrypt on a modern
system; glibc's own libcrypt is deprecated and whether stage 4 built it is
unchecked. **libxcrypt is not pinned.** So "no password" is not a temporary
state being deferred — it is the state until that package exists.

**Phone as authenticator.** Hybrid/caBLE needs BlueZ and is flaky even on
Chromium and Firefox. Treat as unsupported.

**TPM-backed credentials.** tpm2-tss, and for a credential store also
tpm2-pkcs11 with SQLite and libyaml — the largest tail in either report, with
strict version-matching between components. Deferred. It *is* testable in QEMU
aarch64 with swtpm and `tpm-tis-device` (note: not x86's `tpm-tis`).

---

## Reproducibility, and where the non-determinism goes

A password hash is salted, so it is different every time — and the image must
be byte-identical. That looked like a conflict and is not.

**Anything unique to an instance is generated at first boot, into a writable
layer, never baked into the artifact.** Machine id, credential registrations,
any hashes. This is what systemd-firstboot and cloud-init do, and it keeps
`VERON-IMAGE-REPRO-OK` meaning what it means.

**The stronger form, which suits this project specifically:** a read-only base
plus a writable overlay on a second device. The base stays immutable, so
`veron compare` against `files.tsv` works on a **running** system — "every file
traces to a recorded source" becomes continuously verifiable rather than a
claim about build time. Everything written after boot is visibly in the upper
layer by construction.

`guest/init` currently mounts read-only with no persistence at all, so this is
design rather than implementation.

---

## Device permissions without udev

FIDO2 keys are `hidraw` USB HID devices. The standard rules ship as
`70-u2f.rules` and either set `MODE="0664", GROUP="plugdev"` or add
`TAG+="uaccess"`.

**`uaccess` is a logind concept and will not work here**, so the explicit
`GROUP`/`MODE` form is the one to copy. libudev-zero provides enumeration but
runs no daemon and sets no permissions, so an mdev/mdevd rule is what actually
chowns the node.

For console login this is moot — the helper already runs as root. It matters
for the browser and the SSH client, which run unprivileged.

---

## New packages this implies

| package | for | pinned? |
|---|---|---|
| `libcbor` | libfido2's dependency | no |
| `libfido2` | console helper, SSH client | no |
| `openssh` **or** `dropbear` | SSH server | no |
| `libxcrypt` | any password at all, incl. rescue | no |

Four small packages, none with a tail. Worth mirroring early — they are cheap
to pin and remove a blocker from a later wave.

---

## Order

1. **libcbor + libfido2**, and `fido2-token -L` against a key passed into QEMU.
2. **`veron-login`**, with first-boot enrollment into the writable layer.
   **Keep a root rescue path until this is proven.**
3. **SSH**: server first (needs nothing), client second (needs libfido2).
4. **hidraw permissions** via mdevd, for the unprivileged user.
5. **The WebKit transport**, headless first — a touch-only key completes the
   ceremony with no dialog, so passkeys can be demonstrated before the browser
   shell has a URL bar.
6. **The presenter** — touch prompt, PIN entry, credential selection — with the
   shell.

Steps 1–4 are testable in QEMU. Step 5 needs a real key or a software
authenticator.

---

## The failure mode to design against

**Lockout.** A from-source box with only FIDO login and no fallback locks you
out permanently if the key breaks. Enroll **two keys from the start**, and keep
console autologin working until the FIDO path is proven end to end.

This is the one place where the project's usual instinct — remove the thing
that is not strictly needed — is wrong.

---

## Reports

- [`research/2026-08-05-fido2-architecture.md`](./research/2026-08-05-fido2-architecture.md)
  — PAM vs PAM-free across console, SSH and browser; package lists and tails.
- [`research/2026-08-05-webkit-webauthn-backend.md`](./research/2026-08-05-webkit-webauthn-backend.md)
  — what implementing the WebKit backend actually involves, mapped against the
  source tree.

Both are dated because both will age. Where they disagree with something later
observed, the observation wins and this file should say so.
