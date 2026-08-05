# Native 2FA / Passwordless / Passkey (FIDO2/WebAuthn) on Veron: PAM-Based vs PAM-Free Architectures

*Research report, 2026-08-05. Point-in-time — see `research/README.md`.*

*Question asked: what is the best setup for a Linux-based OS to have native
support for 2FA / passwordless / passkeys, covering console login, SSH and
browser WebAuthn, with both a PAM and a PAM-free design presented for
comparison. Authenticators of interest: FIDO2 USB keys, TPM-backed, phone.*

## TL;DR
- **The single smallest coherent design is PAM-free.** Console login and browser WebAuthn can be done directly against libfido2/hidraw, and SSH needs *no* FIDO2 code on the server at all (OpenSSH verifies `ed25519-sk`/`ecdsa-sk` public keys with plain signature math). Adopting linux-PAM buys you a well-trodden config format but pulls in a dependency tail (libaudit, libcap, libxcrypt, and a login program that honors PAM — busybox's does not) for essentially no security benefit on a single-admin box.
- **Browser passkeys are the weak surface.** WebKitGTK/WPE WebKit do **not** implement WebAuthn on Linux at all (the `ENABLE_WEB_AUTHN` flag is OFF and there is no Linux authenticator backend), so a WPE-based browser cannot do passkeys today. Chromium and Firefox do work over USB `/dev/hidraw`, and only phone/hybrid (caBLE) needs BlueZ. Plan for USB security keys only, and treat hybrid/phone as out of scope on Linux.
- **The common core is tiny and shared by both paths:** libcbor + libfido2 (+ hidraw access via a small mdev rule or static-/dev mechanism), OpenSSH built `--with-security-key-builtin`, and a Wayland session started by seatd. TPM-backed credentials are testable in QEMU aarch64 via swtpm + `tpm-tis-device`, but the tpm2-tss/tpm2-pkcs11 stack is the single largest dependency tail and should be deferred.

## Key Findings

### The dependency core is small and mostly shared
Per Yubico's libfido2 page, "The current release of libfido2 is 1.17.0" (the Release Notes date it 2026-04-15, adding CTAP 2.3 support), and "libfido2 depends on libcbor, OpenSSL 3.0 or newer, and zlib. On Linux, libudev (part of systemd) is also required." That is the whole runtime tail for talking to a FIDO2 key. Because Veron already needs OpenSSL and zlib for a browser/TLS stack, the *net new* packages for FIDO2 are just **libcbor** and **libfido2** — plus a `libudev` provider, which is where libudev-zero comes in (Veron already uses libudev-zero, so this is satisfied). Optionally `hidapi` if you build with `-DUSE_HIDAPI=1`, but on Linux libfido2 has a native `hidraw` backend and does not require hidapi.

### SSH: the server needs nothing FIDO-specific
This is the most important architectural finding. OpenSSH 8.2, released 2020-02-14, states in its release notes: "This release adds support for FIDO/U2F hardware authenticators to OpenSSH… FIDO devices are supported by new public key types 'ecdsa-sk' and 'ed25519-sk'." All the hardware interaction is on the **client** side via a middleware library: per the same notes, "communication with the token is managed via a middleware library, specified by the SecurityKeyProvider directive… OpenSSH includes a middleware ('SecurityKeyProvider=internal') with support for USB tokens. It is automatically enabled in OpenBSD and may be enabled in portable OpenSSH via the configure flag --with-security-key-builtin." The **server** only stores an `sk-ssh-ed25519@openssh.com` or `sk-ecdsa-sha2-nistp256@openssh.com` public key in `authorized_keys` and verifies a signature — it does **not** link libfido2, does not touch USB, and does not need PAM. So a Veron box acting purely as an SSH *server* for hardware-key logins needs only: OpenSSH built normally, `PubkeyAuthentication yes`, and `authorized_keys` populated at first boot. If Veron also acts as an SSH *client* using a hardware key, then that build needs `--with-security-key-builtin` + libfido2.

### PAM's real tail is modest but the login program is the catch
linux-pam itself pulls a comparatively small set: on Arch, `pam` links `libaudit`, `libxcrypt` (libcrypt), and historically `libnsl`/`libtirpc`; Gentoo's `sys-libs/pam` adds optional `libcap`/audit. The bigger problem for Veron is not libpam's tail but that **busybox's `login`/`su` applets are not PAM-aware and bypass PAM entirely** — Alpine documents exactly this. So going PAM means *also* replacing busybox login with a PAM-aware login (shadow's `login`, or `util-linux`'s `login`, or a greeter like greetd), which drags in the shadow suite or util-linux — precisely the large dependency tails Veron has deliberately avoided.

### PAM-free FIDO2 login is real and precedented
`pam_u2f` (Yubico) can do either second-factor *or* true passwordless (`sufficient` + no password), and the alpha-stage `pam-fido2` (conte91) does passwordless with resident keys so no username need be typed first. But you don't need PAM at all: libfido2 exposes a clean C API (`fido_assert_*`, `fido_dev_*`) and Veron can ship a ~200-line custom login helper that (1) reads the user's registered credential id + public key from a file, (2) generates a random challenge, (3) calls `fido_dev_get_assert()` with the `hmac-secret` extension and user-verification (PIN/biometric) as configured, (4) verifies the returned signature against the stored public key with `fido_assert_verify()`, and (5) on success `setuid`s and execs a shell/compositor. This is the same ceremony WebAuthn uses, minus the browser/RP layer.

### Session management is already solved without logind
Veron's planned wlroots + labwc + seatd stack does not need logind/PAM for seat management. seatd hands a seat to whoever can access `/run/seatd.socket` (typically gated by the `_seatd` group). The only thing logind/pam_systemd normally provides that seatd does not is `XDG_RUNTIME_DIR` setup — which a login helper or a tiny tool can do (Void uses turnstile/elogind, but you can just `mkdir -p /run/user/$UID` with mode 700 and export the variable). So a passwordless custom-login → export XDG_RUNTIME_DIR → exec labwc chain is fully viable PAM-free.

### Browsers: WebAuthn on Linux is immature and WebKit doesn't do it
- **WebKitGTK / WPE WebKit: no WebAuthn on Linux.** The `ENABLE_WEB_AUTHN` CMake option is defined in `Source/cmake/WebKitFeatures.cmake` as `WEBKIT_OPTION_DEFINE(ENABLE_WEB_AUTHN "Toggle Web AuthN support" PRIVATE OFF)` — default OFF — and the GTK/WPE port options do not enable it; even if forced ON, the only device transport backend in-tree is macOS/IOKit (`IOHIDManager` in `Source/WebKit/UIProcess/WebAuthentication/Cocoa/`) — there is no glib/hidraw backend. The tracking bug is WebKit Bugzilla #205350, "[WPE][GTK] Support WebAuthn," filed by Michael Catanzaro on 2019-12-17 and still NEW/P2 as of mid-2026; a 2026-07-24 PR referenced from it (WebKit PR #70116, commit 317860@main by Lauro Moura of Igalia) appears to be *test gardening*, not a landed backend. GNOME's Epiphany issue #1007 notes "The WebKit code for WebAuthn is all platform-specific. It really needs a WebKit Bugzilla report to implement for WebKitGTK." Catanzaro's GNOME blog (Aug 2024) states verbatim: "Unfortunately for GNOME users, WebKitGTK does not yet support WebAuthn, so passkeys will not work in GNOME Web (Epiphany)… If you require high security, you will unfortunately need to use Firefox or Chrome instead, at least for the time being." So a WPE-WebKit browser on Veron **cannot** do passkeys/WebAuthn today.
- **Chromium** uses its own `device/fido` HID stack over `/dev/hidraw` (no daemon), and implements hybrid/caBLE over **BlueZ** (Bluetooth) — the phone flow is known-flaky on Linux (Chromium devs report it "would reliably crash bluez").
- **Firefox** uses `authenticator-rs`, also talking to `/dev/hidraw` directly (no daemon); USB WebAuthn shipped in Firefox 114.
- The emerging **linux-credentials / credentialsd / libwebauthn** project aims to provide a D-Bus portal (`org.freedesktop.portal.Credentials`) as *the* system WebAuthn API for Linux browsers (including sandboxed Flatpaks), and Catanzaro has said credentialsd is "very likely what we will need to use" for WebKitGTK. It is actively developed (presented at FOSDEM 2026) but the API is not stabilized. libwebauthn uses **hidapi** for USB, **bluez** for BLE, **pcsc/libnfc** for NFC — and is written in **Rust**, which conflicts with Veron's "avoid Rust where possible" rule.

### TPM: works in QEMU but is the biggest tail
TPM-backed credentials require **tpm2-tss** (the core stack: libtss2-esys/mu/rc/tctildr), and for a PKCS#11 credential store also **tpm2-pkcs11** which additionally needs SQLite, libyaml, and at build time tpm2-tools + Python tooling (`tpm2_ptool`). This is a large, interdependent tail with tight version-compatibility constraints between tpm2-tss/tpm2-tools/tpm2-pkcs11. On aarch64 in QEMU you can test it fully: run `swtpm` and attach with `-tpmdev emulator -device tpm-tis-device` (note: aarch64 uses `tpm-tis-device`, not x86's `tpm-tis`); Linux exposes `/dev/tpm0` and `/dev/tpmrm0`. James Bottomley's `tpm-fido` shows a TPM can even be presented as a `/dev/hidraw` FIDO device to browsers. But TPM binds the credential to that one machine.

### Device access without systemd-udev
FIDO2 keys appear as `hidraw` USB HID devices. The standard Yubico udev rules (`70-u2f.rules`) match `KERNEL=="hidraw*", SUBSYSTEM=="hidraw"` on vendor/product IDs and either set `MODE="0664", GROUP="plugdev"` or add `TAG+="uaccess"`. Without systemd-udev, Veron has three options: (1) use libudev-zero + a real device manager (mdev/mdevd or busybox mdev) with an mdev.conf rule that chmod/chowns `/dev/hidraw*`; (2) a static `/dev` with a fixed-permission node if the key is always present; or (3) simply run the login helper as root (it already is) so permissions are moot for console login — only the unprivileged browser/SSH-client case needs the group/mode rule. `uaccess` is a systemd-logind concept and won't work without it, so use the explicit `GROUP`/`MODE` form.

## Details

### A. PAM-based path

**pam_u2f + libfido2 state.** pam_u2f is mature, maintained by Yubico, and builds against **libfido2 (≥1.3.0), libpam, and OpenSSL** (`libfido2-dev libpam-dev libssl-dev`), migrating from autotools to CMake. libfido2's own tail is libcbor + OpenSSL + zlib + libudev. pam_u2f can be *second factor* (`required`) or *passwordless* (`sufficient`, optionally with resident keys). `userverification=1` forces the FIDO2 PIN.

**linux-pam tail.** libpam runtime deps are modest (libaudit, libxcrypt/libcrypt, optionally libcap; historically libnsl/libtirpc for NIS). Build needs flex + a docbook/xslt toolchain for manpages (skippable). The real cost is the **PAM-aware login requirement**: busybox login/su ignore PAM, so you must add shadow or util-linux login, or a greeter — a substantial new tail. Net new packages for the PAM path: **linux-pam, pam_u2f, libcbor, libfido2, + a PAM-aware login (shadow or util-linux) + libxcrypt/libaudit/libcap** ≈ 6–8 packages depending on how much of shadow/util-linux you pull.

**systemd-homed / systemd FIDO2.** systemd-homed supports FIDO2 unlock (`homectl --fido2-device=auto`) using libfido2 and the `hmac-secret` extension, but it is inseparable from systemd (homed, userdbd, pam_systemd_home, D-Bus, the UserRecord JSON model). **None of it is usable without systemd.** Not an option for Veron.

**pam-fido2 alternatives.** `conte91/pam-fido2` (EARLY ALPHA per its README) does passwordless with resident keys and static-links libfido2; `WiSECURE/pam-fido2` is another. All are less mature than pam_u2f.

**TPM PAM.** There is no widely-used `pam_tpm2`; TPM auth on Linux generally goes through tpm2-pkcs11 (a PKCS#11 token backed by the TPM) consumed by pam_pkcs11 or by SSH's `PKCS11Provider`, or via clevis for disk unlock (not interactive login). This is a heavy path.

### B. PAM-free path

libfido2 from a custom login program: the flow is exactly the WebAuthn assertion ceremony — build a `fido_assert_t`, set RP id + client-data hash (your random challenge), call `fido_dev_get_assert()` on `/dev/hidraw*`, optionally with `hmac-secret` and UV, then `fido_assert_verify()` against the stored public key. Resident/discoverable credentials let you skip typing a username. Credential storage: a per-user file (like pam_u2f's `authfile`) containing credential id + COSE public key — this is *public* data, safe to store, but on a reproducible image must be generated into the writable overlay at first-boot enrollment, never baked in.

busybox login has **no hook** for alternative auth (no PAM unless built `CONFIG_PAM=y`, which then still needs libpam). So the clean PAM-free approach is to **not use busybox login for FIDO** — instead run your custom `veron-login` helper directly from dinit on the console tty (replacing the `busybox getty -n -l /bin/sh` autologin with `getty -n -l /usr/bin/veron-login`).

### C. SSH specifically
- Key types: `ed25519-sk` (FIDO2 firmware ≥5.2.3) preferred; `ecdsa-sk` (NIST P-256) works with all U2F/FIDO2 keys.
- Client needs OpenSSH ≥8.2 + libfido2, built `--with-security-key-builtin` (or an external `sk-libfido2.so` middleware via `SecurityKeyProvider`/`SSH_SK_PROVIDER`).
- **Server needs neither libfido2 nor PAM** — just `authorized_keys` with the sk public key and `PubkeyAcceptedAlgorithms` including the sk types (usually already default). The server enforces touch (user-presence) by default; `verify-required` (OpenSSH ≥8.4) adds PIN.
- Usable entirely without PAM: yes — `sshd` with `UsePAM no`, pubkey-only, is the standard hardened config.
- **Smaller servers:** Dropbear added server-side sk-key support in Dropbear 2022.82, released 1 April 2022; its release notes read "Added server support for U2F/FIDO keys (ecdsa-sk and ed25519-sk) in authorized_keys. no-touch-required option isn't allowed yet. Thanks to Egor Duda for the implementation." (enabled via the `DROPBEAR_SK_KEYS` build option). tinyssh does not support sk keys. Given Veron's minimalism, Dropbear is a legitimate smaller alternative to OpenSSH for the server role, and it too needs no libfido2 to *verify* sk keys.

### D. Browser WebAuthn
Covered in Key Findings: WebKitGTK/WPE = no WebAuthn on Linux (flag OFF, macOS-only backend, Bugzilla #205350 NEW). Chromium/Firefox = USB hidraw works, no daemon; hybrid/caBLE needs BlueZ and is flaky. Device permissions handled by the hidraw group/mode rule. The future system API is the linux-credentials D-Bus portal (Rust, not yet stable).

### E. TPM specifics
tpm2-tss (core) → tpm2-pkcs11 (needs SQLite, libyaml, + build-time tpm2-tools/Python) → optionally tpm2-abrmd (resource manager; the kernel `/dev/tpmrm0` in-kernel RM makes abrmd optional). Big, version-sensitive tail. Testable in QEMU aarch64 with swtpm + `tpm-tis-device`.

### F. Device access / permissions
As above: libudev satisfied by libudev-zero for enumeration; actual node permissions need an mdev/mdevd rule or static /dev; `uaccess` unavailable without logind so use explicit `GROUP`/`MODE`.

## Recommendations

**Adopt the PAM-free architecture.** For a single-admin, from-source, no-systemd box, PAM adds a config-file abstraction and a login-program tail without adding security you can't get directly from libfido2 + OpenSSH.

Concrete new-package lists:

- **PAM-free (recommended), console + SSH:** libcbor, libfido2, OpenSSH (`--with-security-key-builtin`), + a small in-house `veron-login` helper (no package, just C against libfido2). **≈3 new packages.** seatd is already planned; libudev-zero already present.
- **PAM-based (for comparison):** linux-pam, pam_u2f, libcbor, libfido2, libxcrypt, libaudit, + shadow *or* util-linux (for a PAM-aware login). **≈6–8 new packages**, several of them the exact large tails Veron avoids.
- **Browser passkeys:** if you need them soon, ship **Chromium or Firefox** (not WPE) and accept their non-trivial tails; USB-key-only. If you stay on WPE WebKit, **passkeys are not available** — revisit when WebKitGTK grows a credentialsd/portal backend.
- **TPM (optional, later):** tpm2-tss (+ tpm2-pkcs11, SQLite, libyaml if you want a PKCS#11 store). Defer.

**Implementation order (early stages testable in QEMU aarch64, no hardware needed using a virtual authenticator or swtpm):**
1. Build libcbor + libfido2; get `fido2-token -L` / `fido2-assert` working against a USB key passed through to QEMU (`-device usb-host`) or a software authenticator.
2. Write and test `veron-login` (challenge/assert/verify) with first-boot enrollment into the writable overlay. Keep a root rescue path.
3. Rebuild OpenSSH with `--with-security-key-builtin`; test sk-key SSH *client* to an external host, and sk-key *server* login (server needs no libfido2).
4. hidraw permissions via mdev/mdevd rule for the unprivileged (browser/ssh-client) user.
5. Wayland session: seatd + `XDG_RUNTIME_DIR` + labwc launched post-login.
6. (Optional) swtpm + tpm2-tss in QEMU; evaluate tpm2-pkcs11 only if TPM-bound credentials are actually wanted.
7. (Optional/blocked) browser passkeys — only via Chromium/Firefox, USB-only.

**Benchmarks that would change the recommendation:**
- If WebKitGTK/WPE lands a working WebAuthn backend (watch Bugzilla #205350 and the credentialsd portal) → revisit browser choice.
- If you need multi-user, remote-managed, or enterprise auth (LDAP/Kerberos) → PAM's pluggability becomes worth its tail.
- If credentialsd stabilizes as a C-consumable D-Bus service (not just Rust) → a shared system authenticator becomes attractive.

## Caveats
- **Lockout risk is the dominant danger.** A from-source box with *only* FIDO login and no password fallback will lock you out permanently if the key is lost/broken. Always keep (a) a second enrolled key, and (b) a root rescue path (a console autologin or a known password in the overlay) until the FIDO path is proven. Enroll two keys from day one.
- **Reproducible-image constraint:** credential public keys, machine-id, and any PINs/hashes must be generated at first boot into the writable overlay, never baked into the byte-for-byte image. Public keys are not secret, but baking them breaks reproducibility and per-device uniqueness.
- **Replay/challenge hygiene:** the custom login helper must generate a fresh random challenge each time and verify the signature + RP id; a naive implementation that reuses challenges or skips `fido_assert_verify()` is trivially bypassable. This is the main reason to lean on libfido2's verify path rather than hand-rolling CBOR.
- **Browser passkeys are genuinely not there on WebKit-Linux** — do not promise them on a WPE-based browser.
- **Hybrid/phone-as-authenticator (caBLE)** is flaky even on Chromium/Firefox on Linux and needs BlueZ; treat as unsupported on Veron.
- **libudev-zero caveat:** it provides enumeration, not hotplug or node permissions by itself; you still need a device manager (mdev/mdevd) or static rule for `/dev/hidraw*` permissions.
- **Rust:** the most promising future path (libwebauthn/credentialsd) is Rust, conflicting with Veron's avoid-Rust preference; the pure-C path tops out at libfido2 + OpenSSH.
- **Version-compatibility** between tpm2-tss/tpm2-tools/tpm2-pkcs11 is notoriously strict; pin known-good matched versions.
