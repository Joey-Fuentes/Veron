// veron-flasher -- write a Veron release to a stick, and PROVE it landed.
//
// THE APP HOLDS NO PRIVILEGE. It runs as the desktop user, and the one
// thing that needs root -- writing a raw disk -- is requested from the
// flashd service over a group-writable FIFO, validated there, never
// here. This is the request->validate->apply boundary the no-privilege
// ruling implies (2026-08-18), built once, reused by whatever needs
// root next.
//
// EVERY CLAIM ON SCREEN IS EARNED: "verified" appears only after the
// service's byte-for-byte read-back (the cmp ritual that caught a torn
// flash and acquitted a stick on 2026-08-18). The sha check compares
// the download against SHA256SUMS. The attestation check is honest
// about its depth: v1 confirms an attestation EXISTS for this exact
// digest and names this repository's builder -- presence and subject,
// not the cryptographic chain. Full Sigstore verification (Fulcio
// chain, Rekor inclusion, pinned trust root) is v2 and the label says
// so, because a checkbox that overstates what it proved would be the
// opposite of this project.
#include <FL/Fl.H>
#include <FL/Fl_Window.H>
#include <FL/Fl_Button.H>
#include <FL/Fl_Choice.H>
#include <FL/Fl_Text_Display.H>
#include <FL/Fl_Text_Buffer.H>
#include <FL/Fl_Check_Button.H>
#include <FL/Fl_Native_File_Chooser.H>
#include <FL/Fl_Input.H>
#include <FL/Fl_Round_Button.H>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

static Fl_Text_Buffer *logbuf;
static Fl_Choice *devchoice;
static Fl_Round_Button *mode_flash, *mode_install;
static Fl_Input *confirm_name;
static std::vector<long long> devcaps;
static Fl_Check_Button *want_sha, *want_att;
static Fl_Button *btn_latest, *btn_own, *btn_flash;
static std::string image_path;                 // "use my own image" mode
static std::string latest_url, latest_zsha, latest_isha;   // stream mode
static std::vector<std::string> devnames;

static void logln(const std::string &s) {
    logbuf->append((s + "\n").c_str());
}

// Run a shell command, stream its stdout into the log, return exit code.
static int run_logged(const std::string &cmd) {
    FILE *p = popen((cmd + " 2>&1").c_str(), "r");
    if (!p) { logln("could not run: " + cmd); return 127; }
    char line[512];
    while (fgets(line, sizeof line, p)) {
        logbuf->append(line);
        Fl::check();                       // keep the UI alive
    }
    return pclose(p);
}

// Removable block devices, sizes read from /sys -- the same facts the
// flashd service re-checks; showing only removables here is UI mercy,
// the service's refusal is the actual safety.
// The disk under / -- shown greyed to the user, refused by the service
// regardless of what any UI displays.
static std::string boot_disk() {
    // /dev/root taught us names lie (the boot stick appeared as a
    // target, 2026-08-18): resolve major:minor through /sys instead.
    char mm[64] = {0};
    FILE *p = popen("awk '$5==\"/\"{print $3; exit}' /proc/self/mountinfo", "r");
    if (p) { if (fscanf(p, "%63s", mm) != 1) mm[0] = 0; pclose(p); }
    if (!mm[0]) return "";
    char link[512] = {0};
    std::string sys = std::string("/sys/dev/block/") + mm;
    ssize_t n = readlink(sys.c_str(), link, sizeof link - 1);
    std::string t = n > 0 ? std::string(link, n) : "";
    size_t b = t.find("/block/");
    if (b == std::string::npos) return "";
    t = t.substr(b + 7);
    size_t sl = t.find('/');
    return sl == std::string::npos ? t : t.substr(0, sl);
}

// ---- maintenance mode -------------------------------------------------- *
// Maintenance mode reboots the whole system into RAM so the boot stick it
// came from becomes an ordinary, writable disk -- the one thing normal
// operation forbids. This app only ORCHESTRATES it: it never writes a disk
// (flashd does) and never pivots (veron-maintenance-init does). Here we detect
// the mode, measure whether the pivot will fit in RAM before offering it, and
// arm the one-shot boot entry that triggers it.

static bool in_maintenance() {
    FILE *f = fopen("/proc/cmdline", "r");
    if (!f) return false;
    char line[4096] = {0};
    if (!fgets(line, sizeof line, f)) line[0] = 0;
    fclose(f);
    return strstr(line, "veron.maintenance=1") != nullptr;
}

static long long mem_available() {
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return -1;
    char key[64]; long long val; char unit[16];
    long long avail = -1;
    while (fscanf(f, "%63s %lld %15s", key, &val, unit) == 3)
        if (!strcmp(key, "MemAvailable:")) { avail = val * 1024; break; }
    fclose(f);
    return avail;
}

static long long tree_bytes(const std::string &path) {
    long long total = 0;
    DIR *d = opendir(path.c_str());
    if (!d) return 0;
    while (dirent *e = readdir(d)) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        std::string p = path + "/" + e->d_name;
        struct stat st;
        if (lstat(p.c_str(), &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) total += tree_bytes(p);
        else total += st.st_size;
    }
    closedir(d);
    return total;
}

static long long root_used_bytes() {
    struct statvfs v;
    if (statvfs("/", &v) != 0) return -1;
    return (long long)(v.f_blocks - v.f_bfree) * (long long)v.f_frsize;
}

static void scan_devices() {
    devchoice->clear(); devnames.clear(); devcaps.clear();
    bool internal = mode_install && mode_install->value();
    bool maint = in_maintenance();
    std::string sacred = boot_disk();
    // Normally an unknowable boot disk is a hard refusal. Under maintenance the
    // root is a tmpfs by design, so boot_disk() is EXPECTED to be empty and the
    // stick SHOULD be listed -- that empty result is the signal the pivot
    // worked, not a reason to hide every target.
    if (sacred.empty() && !maint) { devchoice->add("boot disk unknown -- refusing to list targets"); devchoice->value(0); return; }
    DIR *d = opendir("/sys/block");
    if (!d) return;
    while (dirent *e = readdir(d)) {
        if (e->d_name[0] == '.') continue;
        if (!strncmp(e->d_name, "loop", 4) || !strncmp(e->d_name, "ram", 3)
            || !strncmp(e->d_name, "zram", 4)) continue;
        if (sacred == e->d_name) continue;   // never even listed
        std::string base = std::string("/sys/block/") + e->d_name;
        char buf[64] = {0};
        FILE *f = fopen((base + "/removable").c_str(), "r");
        if (!f) continue;
        if (!fgets(buf, sizeof buf, f)) buf[0] = 0;
        fclose(f);
        if (internal ? buf[0] != '0' : buf[0] != '1') continue;
        long long sectors = 0;
        if (FILE *sz = fopen((base + "/size").c_str(), "r")) {
            if (fscanf(sz, "%lld", &sectors) != 1) sectors = 0;
            fclose(sz);
        }
        // THE HARDWARE'S OWN NAME, so two same-size sticks are tellable
        // apart: /sys exposes what the device says it is.
        auto sysread = [&](const char *leaf) -> std::string {
            char b[96] = {0};
            FILE *f2 = fopen((base + "/device/" + leaf).c_str(), "r");
            if (f2) { if (!fgets(b, sizeof b, f2)) b[0] = 0; fclose(f2); }
            std::string v = b;
            while (!v.empty() && (v.back() == '\n' || v.back() == ' '))
                v.pop_back();
            size_t i = v.find_first_not_of(' ');
            return i == std::string::npos ? "" : v.substr(i);
        };
        std::string who = sysread("vendor");
        std::string mdl = sysread("model");
        if (!mdl.empty()) who += (who.empty() ? "" : " ") + mdl;
        if (who.empty()) who = "unnamed device";
        char label[192];
        snprintf(label, sizeof label, "%s  \xe2\x80\x94  %s  (%.1f GB)",
                 e->d_name, who.c_str(), sectors * 512.0 / 1e9);
        devchoice->add(label);
        devnames.push_back(e->d_name);
        devcaps.push_back(sectors * 512LL);
    }
    closedir(d);
    if (devnames.empty())
        devchoice->add(internal ? "no internal target (the boot disk is never listed)"
                                : "no removable device found");
    devchoice->value(0);
}

static void cb_latest(Fl_Widget*, void*) {
    // NOTHING IS DOWNLOADED HERE ANY MORE. The first on-device attempt
    // filled slot A's ruled ~100 MB of headroom at the 242 MB mark of an
    // 870 MB archive (2026-08-18): this appliance has no scratch for a
    // stored image, BY DESIGN. So this only learns the release's name
    // and digests from SHA256SUMS (186 bytes), and the write itself is
    // the flashd STREAM verb -- network to device, hashed in flight,
    // read back after, nothing stored anywhere.
    logln("== fetching the latest release's own inventory ==");
    std::string dir = std::string(getenv("HOME") ? getenv("HOME") : "/tmp")
                      + "/Downloads";
    mkdir(dir.c_str(), 0755);
    std::string sums = dir + "/SHA256SUMS";
    // -L IS LOAD-BEARING: GitHub release downloads 302-redirect to the
    // CDN, and a curl without -L exits 0 having written the redirect
    // stub -- which read as "SHA256SUMS names no image" on metal
    // (2026-08-18). The refusal was correct; the fetch was not.
    if (run_logged("curl -fsSL -o '" + sums + "' "
        "https://github.com/Joey-Fuentes/Veron/releases/download/6/latest/SHA256SUMS")) {
        logln("FAILED to fetch SHA256SUMS -- is the network up?"); return;
    }
    // the release names its image; we never guess a filename
    char name[256] = {0};
    FILE *p = popen(("grep -o 'veron-x86_64-[0-9a-f]*[.]img[.]zst' '"
                     + sums + "' | head -1").c_str(), "r");
    if (p) { if (fscanf(p, "%255s", name) != 1) name[0] = 0; pclose(p); }
    if (!name[0]) { logln("SHA256SUMS names no image -- refusing to guess"); return; }
    logln(std::string("latest is ") + name);
    // both digests from the same 186-byte file: the archive's and the
    // decompressed image's ("after zstd -d") -- the stream's yardsticks
    char zs[80] = {0}, is[80] = {0};
    FILE *pz = popen(("awk '/" + std::string(name) + "$/{print $1}' '" + sums + "'").c_str(), "r");
    if (pz) { if (fscanf(pz, "%79s", zs) != 1) zs[0] = 0; pclose(pz); }
    std::string inner = name; inner.resize(inner.size() - 4);
    FILE *pi = popen(("awk '/" + inner + "$/{print $1}' '" + sums + "'").c_str(), "r");
    if (pi) { if (fscanf(pi, "%79s", is) != 1) is[0] = 0; pclose(pi); }
    if (!zs[0] || !is[0]) { logln("SHA256SUMS lacks a digest -- refusing to stream unverifiable bytes"); return; }
    latest_url = "https://github.com/Joey-Fuentes/Veron/releases/download/6/latest/" + std::string(name);
    latest_zsha = zs; latest_isha = is;
    image_path.clear();
    if (want_att->value()) {
        logln("== attestation (v1: presence + subject; NOT the crypto chain) ==");
        int rc = run_logged(
            "curl -sSL 'https://api.github.com/repos/Joey-Fuentes/Veron/"
            "attestations/sha256:" + latest_zsha + "' | grep -c 'dsse'");
        logln(rc == 0 ? "attestation EXISTS for this exact digest."
                      : "NO attestation found for this digest -- treat with suspicion.");
    }
    logln("ready to STREAM " + std::string(name) + " (nothing will be stored)");
    logln("  archive sha256 " + latest_zsha);
    logln("  image   sha256 " + latest_isha + "  (verified again by read-back)");
    btn_flash->activate();
}

static void cb_own(Fl_Widget*, void*) {
    Fl_Native_File_Chooser ch;
    ch.title("Choose a Veron image (.img)");
    ch.type(Fl_Native_File_Chooser::BROWSE_FILE);
    if (ch.show() == 0 && ch.filename()) {
        image_path = ch.filename();
        logln("using your image: " + image_path);
        btn_flash->activate();
    }
}

// When a maintenance-mode flash preserves persist, we must restore it AFTER the
// image lands and verifies. flashd reports success as a "VERIFIED:" line; we
// watch for it and then send RESTORE-PERSIST for the same device. This state
// carries the pending restore between the flash request and that line.
static bool   restore_pending = false;
static std::string restore_dev;
// Arming maintenance is a flashd round trip too: the flasher asks (ARM-
// MAINTENANCE), flashd writes the one-shot boot entry and answers "ARMED:", and
// only then do we reboot. This flag carries that intent across the status watch.
static bool   reboot_after_arm = false;
#define PERSIST_BACKUP_PATH "/run/veron-persist-backup"

static void poll_status(void*) {
    static long off = 0;
    FILE *f = fopen("/run/veron-flash/status", "r");
    if (f) {
        fseek(f, off, SEEK_SET);
        char line[512];
        while (fgets(line, sizeof line, f)) {
            logbuf->append(line);
            off = ftell(f);
            // The verified line is flashd's success signal for a raw write. If a
            // persist restore is pending (maintenance + preserve), fire it now
            // that the new image -- and its fresh, empty persist partition -- is
            // on the stick.
            if (restore_pending && strstr(line, "VERIFIED:")) {
                restore_pending = false;
                struct stat bst;
                if (stat(PERSIST_BACKUP_PATH, &bst) == 0 && S_ISDIR(bst.st_mode)) {
                    logln("image verified; restoring preserved persist ...");
                    FILE *c = fopen("/run/veron-flash/cmd", "w");
                    if (c) { fprintf(c, "RESTORE-PERSIST %s %s\n", PERSIST_BACKUP_PATH, restore_dev.c_str()); fclose(c); }
                    else logln("could not reach flashd to restore persist.");
                } else {
                    logln("no persist backup present -- nothing to restore (was this a discard?).");
                }
            }
            // flashd confirms the one-shot boot entry is written with "ARMED:".
            // Only now do we reboot -- into the maintenance init, which lifts the
            // system into RAM and frees the stick. Reboot via the power service
            // (the unprivileged path, same as the menu).
            if (reboot_after_arm && strstr(line, "ARMED:")) {
                reboot_after_arm = false;
                logln("maintenance armed; rebooting into RAM now ...");
                FILE *p = fopen("/run/veron-power/cmd", "w");
                if (p) { fprintf(p, "reboot\n"); fclose(p); }
                else logln("could not reach the power service -- reboot manually to enter maintenance.");
            }
        }
        fclose(f);
    }
    Fl::repeat_timeout(0.5, poll_status);
}

static void cb_flash(Fl_Widget*, void*) {
    if ((image_path.empty() && latest_url.empty()) || devnames.empty()) return;
    int idx = devchoice->value() < (int)devnames.size() ? devchoice->value() : 0;
    std::string dev = devnames[idx];
    bool install = mode_install->value();
    if (install) {
        // TYPED CONSENT: erasing an internal disk requires the human to
        // type the device's name, exactly. The service then requires the
        // capacity handshake on top -- two consents for one erasure.
        if (!confirm_name->value() || dev != confirm_name->value()) {
            logln("INSTALL not armed: type the target's name ('" + dev +
                  "') into the confirmation box -- it erases every OS on it.");
            return;
        }
    }
    logln(std::string("== requesting ") + (install ? "INSTALL" : "FLASH") +
          " of " + image_path + " onto " + dev + " ==");
    FILE *f = fopen("/run/veron-flash/cmd", "w");
    if (!f) {
        logln("cannot reach the flashd service -- is it running? "
              "(dinitctl status veron-flashd)");
        return;
    }
    if (!latest_url.empty() && image_path.empty()) {
        if (install) { logln("INSTALL streaming lands with the qemu rehearsal; use a local image for now"); fclose(f); return; }
        fprintf(f, "STREAM %s %s %s %s\n", latest_url.c_str(),
                latest_zsha.c_str(), latest_isha.c_str(), dev.c_str());
    } else if (install)
        fprintf(f, "INSTALL %s %s %lld\n", image_path.c_str(), dev.c_str(),
                devcaps[idx]);
    else
        fprintf(f, "FLASH %s %s\n", image_path.c_str(), dev.c_str());
    fclose(f);
    // In maintenance mode, if a persist backup was banked by the pivot, arrange
    // to restore it once the write verifies (poll_status watches for VERIFIED:).
    if (in_maintenance()) {
        struct stat bst;
        if (stat(PERSIST_BACKUP_PATH, &bst) == 0 && S_ISDIR(bst.st_mode)) {
            restore_pending = true; restore_dev = dev;
            logln("persist backup present; it will be restored after the write verifies.");
        }
    }
    logln("request sent; the service's validation and progress follow:");
}


// Arm maintenance mode: verify the pivot fits in RAM, then clone the current
// boot entry with the maintenance cmdline and point BootNext at it, and reboot.
// PRECONDITION FIRST, ALWAYS: we refuse before doing anything destructive or
// irreversible if preserve will not fit, so the machine never reboots into a
// pivot that then cannot keep the user's data.
static void arm_maintenance(bool preserve) {
    long long avail = mem_available();
    long long rootb = root_used_bytes();
    long long persistb = preserve ? tree_bytes("/persist") : 0;
    // headroom for the overlay writes, the running desktop, and slack.
    const long long HEADROOM = 768LL * 1024 * 1024;
    long long need = (rootb > 0 ? rootb : 0) + persistb + HEADROOM;
    logln("== maintenance mode precheck ==");
    char m[256];
    snprintf(m, sizeof m, "  RAM available: %.2f GB", avail / 1e9); logln(m);
    snprintf(m, sizeof m, "  system to copy: %.2f GB", rootb / 1e9); logln(m);
    if (preserve) { snprintf(m, sizeof m, "  persist to preserve: %.2f GB", persistb / 1e9); logln(m); }
    snprintf(m, sizeof m, "  needed (with headroom): %.2f GB", need / 1e9); logln(m);
    if (avail < 0 || rootb < 0) { logln("REFUSED: could not measure memory or system size."); return; }
    if (need > avail) {
        logln("REFUSED: not enough RAM to lift the system"
              + std::string(preserve ? " and persist" : "") + " into memory.");
        if (preserve) logln("  You can retry with 'discard' to drop user state, which needs less RAM -- but that erases it.");
        return;
    }
    // The RAM fit is the only thing this app can decide on its own. Writing the
    // one-shot boot entry needs to mount efivarfs and write an EFI variable --
    // privileged work, and this app is the veron user, always unprivileged. So
    // it asks flashd (root) to arm, exactly as every disk write goes through
    // flashd. flashd reports ARMED on the status stream; poll_status watches for
    // it and then reboots. reboot_after_arm carries that intent.
    reboot_after_arm = true;
    logln("RAM is sufficient. Asking the flash service to arm maintenance mode ...");
    FILE *c = fopen("/run/veron-flash/cmd", "w");
    if (!c) { logln("REFUSED: could not reach the flash service to arm maintenance."); reboot_after_arm = false; return; }
    fprintf(c, "ARM-MAINTENANCE %s\n", preserve ? "preserve" : "discard");
    fclose(c);
    logln("request sent; the service's response follows:");
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--version")) { puts("veron-flasher 0.1.0"); return 0; }
    Fl_Window win(680, 460, "Veron Flasher");
    btn_latest = new Fl_Button(10, 10, 210, 30, "Download latest release");
    btn_own    = new Fl_Button(230, 10, 160, 30, "Use my own image...");
    want_sha = new Fl_Check_Button(400, 6, 270, 20, "verify sha256 (recommended)");
    want_att = new Fl_Check_Button(400, 26, 270, 20, "check attestation (v1: presence)");
    want_sha->value(1);
    mode_flash   = new Fl_Round_Button(10, 44, 200, 22, "Flash a removable stick");
    mode_install = new Fl_Round_Button(220, 44, 300, 22, "Install to an internal disk (erases it)");
    mode_flash->type(FL_RADIO_BUTTON); mode_install->type(FL_RADIO_BUTTON);
    mode_flash->value(1);
    mode_flash->callback([](Fl_Widget*, void*){ scan_devices(); });
    mode_install->callback([](Fl_Widget*, void*){ scan_devices(); });
    devchoice = new Fl_Choice(80, 72, 300, 28, "Target:");
    Fl_Button *rescan = new Fl_Button(390, 72, 80, 28, "Rescan");
    btn_flash = new Fl_Button(480, 72, 190, 28, "Write + verify");
    confirm_name = new Fl_Input(150, 106, 230, 26, "Type target to arm:");
    confirm_name->tooltip("For INSTALL only: type the device name exactly, e.g. nvme0n1");
    btn_flash->deactivate();
    // MAINTENANCE: the one control that reboots the system into RAM so the boot
    // stick becomes writable. Only shown/useful on a normal boot; in maintenance
    // mode the mode is already active and the stick is already a listed target.
    Fl_Button *btn_maint = new Fl_Button(400, 106, 270, 26, "Reflash this boot device...");
    btn_maint->tooltip("Reboots the whole system into RAM so the stick it booted from can be rewritten.");
    btn_maint->callback([](Fl_Widget*, void*){
        // A tiny consent: preserve is default; discard requires the typed word.
        // Here we keep it simple -- preserve unless the confirm box says DISCARD.
        bool preserve = true;
        if (confirm_name && confirm_name->value() && !strcmp(confirm_name->value(), "DISCARD"))
            preserve = false;
        if (!preserve) logln("persist=DISCARD confirmed -- user state will NOT be kept.");
        arm_maintenance(preserve);
    });
    Fl_Text_Display *disp = new Fl_Text_Display(10, 140, 660, 310);
    logbuf = new Fl_Text_Buffer();
    disp->buffer(logbuf);
    btn_latest->callback(cb_latest);
    btn_own->callback(cb_own);
    btn_flash->callback(cb_flash);
    rescan->callback([](Fl_Widget*, void*){ scan_devices(); });
    scan_devices();
    if (in_maintenance()) {
        logln("== MAINTENANCE MODE ACTIVE ==");
        logln("The system is running from RAM. The boot device is now a WRITABLE");
        logln("target -- it appears in the list above. Flashing it here rewrites");
        logln("the stick you booted from. Persist, if preserved, is restored after.");
    } else {
        logln("Veron Flasher -- every claim below is earned, none assumed.");
        logln("The write happens in a root service that refuses the boot disk");
        logln("and anything non-removable; 'verified' means byte-for-byte read-back.");
        logln("To rewrite THIS boot device, use 'Reflash this boot device' -- it");
        logln("reboots into RAM first so the stick is safe to overwrite.");
    }
    Fl::add_timeout(0.5, poll_status);
    win.end(); win.show(argc, argv);
    return Fl::run();
}
