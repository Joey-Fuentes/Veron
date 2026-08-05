# Implementing a WebAuthn (Passkey) Backend for WPE WebKit / WebKitGTK on Veron

*Research report, 2026-08-05. Point-in-time — see `research/README.md`.*

*Question asked: given that the browser shell is ours to write anyway, what is
the minimal engineering work to implement the WebAuthn backend ourselves and
see passkeys working with USB FIDO2 keys?*

## TL;DR
- **The minimal work is to write a Linux `hidraw`-based transport for WebKit's *existing* CTAP engine** — a new `AuthenticatorTransportService`/`HidService` plus a `HidConnection` that opens `/dev/hidraw*`, filters for the FIDO usage page `0xF1D0`, and does report read/write. WebKit already implements all of CTAP1/CTAP2, CBOR, HID framing, channel allocation and the PIN protocol in platform-independent C++ (`Source/WebCore/Modules/webauthn/fido/` and `Source/WebKit/UIProcess/WebAuthentication/fido/`), so you do **not** reimplement CTAP — you supply device I/O only. Estimated ~1,000–2,000 LOC across a handful of new files, plus flipping `ENABLE_WEB_AUTHN` on for the GLib ports and wiring `AuthenticatorTransportService::create()`.
- **Nobody has upstreamed this yet.** WebKit Bugzilla #205350 is still `NEW`; the only 2026 activity (Lauro Moura's PR #70116, closed by EWS as "Test gardening commit `317860@main` (77d3d67a5d49)", July 24, 2026) contains no backend code — just one line in `WebDriverTests/TestExpectations.json`. Upstream's stated direction is to consume the Rust **credentialsd** D-Bus portal so it works under Flatpak — per Catanzaro in #205350 comment 4 (Oct 22, 2025): *"The linux-credentials project's credentialsd API is not ready yet, but is very likely what we will need to use… That's designed to be a portal, so we only need one implementation, not separate implementations for host system vs. Flatpak."* For a non-Flatpak, from-source distro like Veron, that portal objection does not apply, so a direct in-process hidraw backend is both simpler and legitimate.
- **Do not build Chromium.** For a package-by-package, pinned, reproducible aarch64 distro that prefers C/C++ and small dependency tails, Chromium is the worst possible fit (multi-hour builds, mandatory Rust, `depot_tools`/`gclient` non-reproducible network vendoring, bundled toolchain, tens of GB of source). Firefox is more tractable but its WebAuthn is Rust (`authenticator-rs`). Patching WPE WebKit is by far the cheapest path to browser passkeys on Veron.

## Key Findings

**1. WebKit's WebAuthn code is cleanly layered, and only the bottom (device transport) layer is macOS-specific.** The DOM API and the entire FIDO/CTAP protocol stack are platform-independent C++. The Cocoa port only supplies (a) HID device discovery/I/O via IOKit, (b) a Touch ID/Keychain platform authenticator (`LocalAuthenticator`), and (c) ASAuthorization-based UI. A Linux port needs to reimplement only (a); (b) and (c) are optional for a first demonstration.

**2. The "minimal path" is Option (a): reuse WebKit's CTAP, write only the hidraw transport.** WebKit's `CtapHidDriver` already does HID packet framing and message assembly; `CtapAuthenticator`/`U2fAuthenticator` already speak CTAP2/CTAP1. The Cocoa `HidService` is a thin discovery layer and `HidConnection` is a thin report-I/O wrapper. You replace those two Cocoa classes with hidraw equivalents.

**3. Using `libfido2` as the backend (Option b) is possible but is *not* the minimal path** given WebKit's API shapes. `libfido2` is a high-level, blocking, whole-ceremony API (`fido_dev_get_assert`, `fido_cred_verify`) that does its own enumeration and CTAP. It plugs in at WebKit's `Authenticator` level, not the `HidConnection` level, so you'd bypass and duplicate WebKit's existing CTAP engine and adapt a blocking API into WebKit's async, callback-driven `AuthenticatorManager`. It's a larger conceptual mismatch than just supplying hidraw I/O. (`libfido2` remains the right choice for the separately-planned SSH/login helper, where blocking is fine.)

**4. The credentialsd portal (Option c) is upstream's preferred long-term design but the wrong fit for Veron now.** It exists to solve Flatpak sandboxing by centralizing device access in one D-Bus service. Veron has no Flatpak, no systemd, and prefers C/C++/small deps; credentialsd and libwebauthn are Rust. Implementing a D-Bus client in WebKit *and* running a Rust daemon is strictly more work and more dependencies than a direct hidraw backend.

## Details

### WebKit's WebAuthn architecture (mapped from source)

WebAuthn spans three process layers:

- **DOM / WebProcess:** `Source/WebCore/Modules/webauthn/` implements `navigator.credentials.create()/get()` (`PublicKeyCredential`, `AuthenticatorResponse`, etc.). `Source/WebKit/WebProcess/WebAuthentication/WebAuthenticatorCoordinator.cpp` marshals requests to the UI process.
- **Platform-independent FIDO/CTAP engine (the part you get for free):**
  - `Source/WebCore/Modules/webauthn/cbor/` — the CBOR encoder/decoder.
  - `Source/WebCore/Modules/webauthn/fido/` — `DeviceRequestConverter.cpp` (builds CTAP `makeCredential`/`getAssertion` CBOR), `DeviceResponseConverter.cpp` (parses `authenticatorGetInfo`/responses), `U2fCommandConstructor.cpp`, `U2fResponseConverter.cpp`, `AuthenticatorGetInfoResponse.cpp`, `Pin.cpp` (CTAP2 clientPIN protocol). All compiled into WebCore for every port, gated by `ENABLE(WEB_AUTHN)`.
  - `Source/WebKit/UIProcess/WebAuthentication/fido/` — `FidoService.cpp`, `CtapAuthenticator.cpp/.h`, `CtapDriver.h` (abstract base with `transport()`, `protocol()`, `setMaxMsgSize()`, `cancel()`), `CtapHidDriver.cpp/.h` (HID packet framing, channel allocation via a `Worker`), `CtapNfcDriver`, `CtapCcidDriver`, `U2fAuthenticator.cpp`, `FidoAuthenticator.cpp`. This is CTAP-over-HID **fully implemented and platform-independent** — it consumes an abstract `HidConnection`.
- **UI-process orchestration + platform transport:**
  - `AuthenticatorManager.cpp/.h` — top-level state machine; `collectTransports()`/`filterTransports()` decide which transport services to spin up; `respondReceived()`, `clearStateAsync()`, timeout timer.
  - `Authenticator.cpp` — abstract authenticator.
  - `AuthenticatorTransportService.cpp/.h` — **the abstract factory a new port must implement.** `AuthenticatorTransportService::create()` dispatches by transport type (USB/HID, NFC, CCID, internal); `createMock()` returns the mock. Today the real `create()` paths live in `SourcesCocoa.txt`.
  - `WebAuthenticatorCoordinatorProxy` — has a cross-platform `.cpp` **and** a Cocoa `.mm`; the Cocoa one uses AuthenticationServices (ASC) for the system UI.
  - `Cocoa/` — the macOS transport/UI: `HidService.mm` (discovery via `IOHIDManager` with matching dictionary `{PrimaryUsagePage: 0xf1d0, PrimaryUsage: 0x01}`), `HidConnection.mm` (send via `IOHIDDeviceSetReport`, receive via `IOHIDDeviceRegisterInputReportCallback`, plus a `sendSync`), `LocalService.mm`/`LocalAuthenticator.mm` (Touch ID/Keychain platform authenticator via LocalAuthentication.framework), `NfcService.mm`, `CcidService.mm`, `AuthenticatorPresenterCoordinator.mm`, `WKASCAuthorizationPresenterDelegate.mm`.
  - `Mock/` — `MockHidService`, `MockHidConnection`, `MockAuthenticatorManager` for layout/API tests.
  - `Virtual/` — `VirtualService.mm`, `VirtualHidConnection`, `VirtualAuthenticatorManager`, `VirtualAuthenticatorUtils` — the WebDriver **virtual authenticator** used to run the WPT `webauthn/` suite without hardware.

The Cocoa `HidService.h` interface is small and is the template for the Linux port: it derives from `FidoService`, exposes `startDiscoveryInternal()`, a virtual `platformStartDiscovery()`, and a virtual `createHidConnection()`. The `HidConnection` surface is `initialize()`, `terminate()`, `send()`, `registerDataReceivedCallback()`/`unregisterDataReceivedCallback()`, `receiveReport()`.

**What `ENABLE(WEB_AUTHN)` gates, and what breaks if you flip it on today:** It is defined `WEBKIT_OPTION_DEFINE(ENABLE_WEB_AUTHN "Toggle Web AuthN support" PRIVATE OFF)` in `Source/cmake/WebKitFeatures.cmake` and is *not* overridden in `Source/cmake/OptionsWPE.cmake` (confirmed absent in the current main/2.53.x tree) or `OptionsGTK.cmake`, so both GLib ports build with WebAuthn off. Turning it on for the GLib ports without adding a transport will fail to build/link: `AuthenticatorTransportService::create()`'s real (non-mock) implementations and the whole `Cocoa/` transport live in `SourcesCocoa.txt`, so a non-Cocoa build has no concrete `HidService`/`LocalService`/`HidConnection` and no ASC coordinator. The work is precisely to provide those GLib implementations and add them to the WPE/GTK `Sources` lists.

### The minimal Linux backend (Option a), concretely

New/changed files (names illustrative, following WebKit conventions):

- `UIProcess/WebAuthentication/glib/HidServiceGLib.cpp/.h` — enumerate `/dev/hidraw*` (scan `/sys/class/hidraw` or use the `libudev-zero` shim you already ship), read each device's HID report descriptor, keep only devices whose usage page is `0xF1D0`; emit `authenticatorAdded()` with a `CtapHidAuthenticator` per device. ~150–300 LOC including hotplug handling via a GLib `GSource`/inotify or mdevd-driven rescan.
- `UIProcess/WebAuthentication/glib/HidConnectionGLib.cpp/.h` — wrap an opened hidraw fd; `send()` = `write()` a 64-byte HID output report; a read thread or `GSource` watching the fd calls `receiveReport()`/the data-received callback on input reports. Implement the `sendSync` semantics WebKit's `CtapHidDriver` expects. ~150–300 LOC.
- `AuthenticatorTransportService.cpp` — add the non-Cocoa `create()` branch returning `HidServiceGLib` for the USB/HID transport (a few lines, `#if USE(GLIB)`).
- `WebAuthenticatorCoordinatorProxy` — the cross-platform `.cpp` already exists; add a minimal GLib `performRequest`/presenter path. For a first demo this can be **headless** (no dialog; ceremony proceeds and the user simply touches the blinking key).
- `Source/cmake/OptionsWPE.cmake` and `OptionsGTK.cmake` — `WEBKIT_OPTION_DEFAULT_PORT_VALUE(ENABLE_WEB_AUTHN PRIVATE ON)` (or gate behind experimental features initially).
- `Source/WebKit/PlatformWPE.cmake` / `PlatformGTK.cmake` and the port `Sources` lists — add the new files.

You do **not** implement `LocalAuthenticator` (no platform authenticator — Veron has no Touch ID/Keychain equivalent; only roaming USB keys). `isUserVerifyingPlatformAuthenticatorAvailable()` returns false, which is correct.

**Upstreamability:** A direct hidraw backend is unlikely to be accepted upstream. Catanzaro stated verbatim in #205350 comment 3 (Mar 11, 2024): *"I won't accept new static permissions into Epiphany and other app developers shouldn't either, and adding functionality into WebKit that doesn't work under flatpak is not OK, so a portal is surely the next step."* So for Veron this is a **carried downstream patch**. The maintenance burden is moderate: the code you touch (`fido/`, `AuthenticatorManager`, transport service) is relatively stable, but WebKit's tree moves fast and the WebAuthn files see periodic refactors (smart-pointer/weak-ref churn, feature-flag cleanups, new CTAP features like Set-PIN and CCID), so expect to rebase your ~thousand-line patch every release.

### What "working" requires end-to-end on Veron

- **Device permissions without systemd-udev.** `/dev/hidraw*` nodes must be readable/writable by the browser user. On systemd distros this is done by udev rules (libfido2 ships `70-u2f.rules`). On Veron (libudev-zero + mdevd, no udev daemon): add an mdevd rule that chowns/chmods hidraw nodes belonging to FIDO devices (match on the USB device or on the report descriptor usage page `0xF1D0`). Note `libudev-zero` provides enumeration/monitor shims but runs no daemon, so hotplug reaction comes from mdevd.
- **Sandbox interaction.** WebKit's bubblewrap sandbox confines the **WebContent** and **Network** processes, *not* the UI process. WebAuthn's `AuthenticatorManager`/`HidService` run in the **UI process** (your launcher — cog/MiniBrowser), which is not bubblewrapped. So hidraw access happens in the unsandboxed UI process and the WebContent sandbox does not need a hidraw hole. This is exactly why Apple put HID in the UIProcess.
- **User-facing UI.** Cocoa uses `AuthenticatorPresenterCoordinator`/ASAuthorization to show "touch your key" and to collect a PIN. For a first demonstration you can go **headless**: with a security key that gates on user *presence* only (touch, no PIN/UV), the ceremony completes with no dialog. PIN/UV entry is the main thing that genuinely needs UI; defer it. The GLib ports have an `APIWebAuthenticationPanel` scaffold you can later wire to a GTK dialog or a WPE overlay.
- **Test infrastructure that proves it without hardware.** WebKit ships `Mock/` (MockHidService/MockHidConnection, used by layout tests and `TestWebKitAPI`) and the WebDriver **virtual authenticator** in `Virtual/` (used by the WPT `webauthn/` suite). To run WPT webauthn on Linux you'd want the virtual authenticator enabled for the GLib port (its `VirtualService`/`VirtualHidConnection` are currently partly `.mm`). Externally, software authenticators exist for CI: `virtual-fido`, SoftFIDO2-style emulators, and `umockdev` to simulate a hidraw device node.

### Practical demonstration path

1. Build WPE WebKit with `ENABLE_WEB_AUTHN=ON` and your `HidServiceGLib`/`HidConnectionGLib`.
2. Add the mdevd rule so the launcher user can open the key's hidraw node.
3. Launch cog/MiniBrowser on labwc/Wayland and visit a test RP: **webauthn.io** or Duo's **webauthn.me** are the fastest; alternatively run the WPT `webauthn/` server locally.
4. Register (create) then authenticate (get) with a USB FIDO2 key (e.g. YubiKey/SoloKey). Touch the key on the blinking prompt.
5. Hardware-free variants: run in QEMU with USB passthrough of a real key (`-device usb-host,...`), or use a virtual/software authenticator + `umockdev` for CI, or exercise the ceremony through WebKit's own virtual authenticator via WebDriver.

### Chromium vs. Firefox vs. patching WebKit (the reality check)

- **Chromium from source on aarch64 is impractical for Veron.** A community Arch Linux ARM build report (Chromium 134) states plainly: *"This took almost 11 hours to build on Radxa Orion O6 with those A720 cores… it has 64GB [RAM]."* The build mandates Rust (nightly in some configs), and `depot_tools`/`gclient` fetch hundreds of pinned third-party repos over the network via ~170 sync hooks (non-reproducible, and `gn` ships as an amd64 prebuilt); checkouts run into the tens of GB before build artifacts, and ~100 GB of free disk is the documented minimum. It bundles its own copy of essentially every dependency — the antithesis of a package-by-package, pinned, declared-dependency distro. Its WebAuthn is excellent, but the cost of entry is prohibitive.
- **Firefox is more tractable but still a poor fit:** multi-hour builds, mandatory Rust + a vendored cargo tree, and its USB FIDO2 support is the Rust `authenticator-rs` crate. Notably, per Mozilla's official release notes, **Firefox 114.0 (released June 6, 2023)** added exactly this: *"Users on macOS, Linux, and Windows 7 can now use FIDO2 / WebAuthn authenticators over USB. Some advanced features, such as fully passwordless logins, require a PIN to be set on the authenticator."* That is a useful existence proof that a direct in-process hidraw approach works on Linux and does **not** strictly require the credentialsd portal.
- **Patching WPE WebKit wins** on every axis that matters to Veron: you're already building WebKit, the added code is C/C++, the only new "dependency" is the kernel's hidraw interface (and optionally your existing libudev-zero), and the CTAP engine is already in-tree.

## Recommendations

**Stage 1 — Prove the engine works (days).** Build WPE with `ENABLE_WEB_AUTHN=ON` and the **mock/virtual** authenticator wired for the GLib port; run the WPT `webauthn/` subset and `TestWebKitAPI` WebAuthn tests. This validates that WebKit's CTAP/CBOR engine builds and runs on aarch64/glibc with no hardware and isolates the transport as the only missing piece. *Threshold to proceed:* mock-backed create()/get() pass.

**Stage 2 — Write the hidraw transport (1–3 weeks).** Implement `HidServiceGLib` + `HidConnectionGLib`, wire `AuthenticatorTransportService::create()`, run **headless** (no dialog), test against a PIN-less/touch-only USB key on webauthn.io. Add the mdevd permission rule. *Threshold:* a real registration+assertion round-trips against webauthn.io.

**Stage 3 — Make it usable (2–4 weeks).** Add a minimal presenter (a GTK dialog for GTK; a WPE overlay or app-provided callback for WPE headless embedded) for "touch your key," PIN entry, and multi-credential selection. Handle hotplug cleanly via mdevd. *Threshold:* PIN-protected keys and account selection work.

**Stage 4 — Decide on upstreaming.** Keep the hidraw backend as a **carried downstream patch** for Veron. Separately, if you ever want Flatpak/Epiphany compatibility or upstream acceptance, watch the **credentialsd** portal API; once it stabilizes, a D-Bus client could be added *alongside* the hidraw backend. Re-evaluate if credentialsd reaches a 1.0 API and a WebKit branch appears on #205350.

**Reuse `libfido2` only where it fits:** your SSH/PAM-free login helper, not the browser. Don't try to make WebKit's async `Authenticator` sit on top of libfido2's blocking whole-ceremony API — supplying hidraw I/O to WebKit's own CTAP is less code.

## Caveats
- **Any assumption that a real WPE/GTK WebAuthn backend merged in July 2026 is incorrect.** PR #70116 was closed by EWS as *"Test gardening commit 317860@main (77d3d67a5d49)"* — one line in `WebDriverTests/TestExpectations.json`, no backend; Bugzilla #205350 remains `NEW` (assignee Lauro Moura, P2, Enhancement). There is no upstream hidraw or portal backend to copy — you are implementing this, guided by the Cocoa reference.
- **LOC and time estimates are inferences** from the Cocoa file sizes and the shape of `HidService.h`/`HidConnection`, not measured from an existing Linux patch (none exists). Treat ~1,000–2,000 LOC and the week ranges as order-of-magnitude planning figures.
- **No platform authenticator** means WPT tests that require an internal/platform authenticator (platform attachment, `isUVPAA()===true`) will fail or be skipped; roaming/cross-platform USB tests pass. The WebDriver virtual authenticator can emulate platform authenticators for conformance if you invest in enabling it for the GLib port.
- **Maintenance burden is real:** WebKit's WebAuthn files are refactored regularly, so a downstream patch needs rebasing every release.
- **Spec currency:** WebKit's WebAuthn implementation is actively maintained toward Level 2/3 (recent work on `getClientCapabilities()`, related origins, PRF, CCID smart-card support, CTAP2 Set-PIN). The shared WebCore/fido engine is current; it's the *Linux transport and UI*, not the protocol, that's missing.
- I could not independently confirm the byte-for-byte contents of `OptionsGTK.cmake`'s WebAuthn line (inferred OFF from the global `WebKitFeatures.cmake` default and the unresolved bug), nor retrieve exact Cocoa `HidService.mm`/`HidConnection.mm` line counts; the transport-surface description is reconstructed from the public `HidService.h` and multiple WebKit changelog/commit excerpts.
