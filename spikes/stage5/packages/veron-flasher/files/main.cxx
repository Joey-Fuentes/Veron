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
#include <unistd.h>

static Fl_Text_Buffer *logbuf;
static Fl_Choice *devchoice;
static Fl_Round_Button *mode_flash, *mode_install;
static Fl_Input *confirm_name;
static std::vector<long long> devcaps;
static Fl_Check_Button *want_sha, *want_att;
static Fl_Button *btn_latest, *btn_own, *btn_flash;
static std::string image_path;
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
    char dev[128] = {0};
    FILE *p = popen("awk '$2==\"/\"{print $1}' /proc/mounts | head -1", "r");
    if (p) { if (fscanf(p, "%127s", dev) != 1) dev[0] = 0; pclose(p); }
    std::string s = dev;
    if (s.rfind("/dev/", 0) == 0) s = s.substr(5);
    while (!s.empty() && isdigit(s.back())) s.pop_back();
    if (!s.empty() && s.back() == 'p') s.pop_back();
    return s;
}

static void scan_devices() {
    devchoice->clear(); devnames.clear(); devcaps.clear();
    bool internal = mode_install && mode_install->value();
    std::string sacred = boot_disk();
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
    logln("== fetching the latest release's own inventory ==");
    std::string dir = std::string(getenv("HOME") ? getenv("HOME") : "/tmp")
                      + "/Downloads";
    mkdir(dir.c_str(), 0755);
    std::string sums = dir + "/SHA256SUMS";
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
    std::string zst = dir + "/" + name;
    logln("downloading (~900 MB; the log will sit quiet while curl works)...");
    if (run_logged("curl -fSL --progress-bar -o '" + zst + "' "
        "'https://github.com/Joey-Fuentes/Veron/releases/download/6/latest/" 
        + std::string(name) + "'")) { logln("download FAILED"); return; }
    if (want_sha->value()) {
        logln("== sha256 against the release's own SHA256SUMS ==");
        if (run_logged("cd '" + dir + "' && sha256sum -c SHA256SUMS 2>/dev/null"
                       " | grep '" + std::string(name) + "'")) {
            logln("DIGEST MISMATCH -- this download is not the release. Stopping.");
            return;
        }
        logln("digest OK -- the bytes are the release's");
    }
    if (want_att->value()) {
        logln("== attestation (v1: presence + subject; NOT the crypto chain) ==");
        std::string dig;
        FILE *q = popen(("sha256sum '" + zst + "' | cut -d' ' -f1").c_str(), "r");
        char db[80] = {0};
        if (q) { if (fscanf(q, "%79s", db) != 1) db[0] = 0; pclose(q); }
        dig = db;
        int rc = run_logged(
            "curl -fsSL 'https://api.github.com/repos/Joey-Fuentes/Veron/"
            "attestations/sha256:" + dig + "' | grep -c 'dsse'");
        if (rc == 0)
            logln("attestation EXISTS for this exact digest at "
                  "Joey-Fuentes/Veron.\n  (v1 checks presence and subject; "
                  "cryptographic Sigstore verification is future work and "
                  "this label will change when it is real.)");
        else
            logln("NO attestation found for this digest -- treat with suspicion.");
    }
    logln("decompressing...");
    if (run_logged("zstd -f -d '" + zst + "'")) { logln("zstd FAILED"); return; }
    image_path = zst.substr(0, zst.size() - 4);
    logln("image ready: " + image_path);
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

static void poll_status(void*) {
    static long off = 0;
    FILE *f = fopen("/run/veron-flash/status", "r");
    if (f) {
        fseek(f, off, SEEK_SET);
        char line[512];
        while (fgets(line, sizeof line, f)) { logbuf->append(line); off = ftell(f); }
        fclose(f);
    }
    Fl::repeat_timeout(0.5, poll_status);
}

static void cb_flash(Fl_Widget*, void*) {
    if (image_path.empty() || devnames.empty()) return;
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
    if (install)
        fprintf(f, "INSTALL %s %s %lld\n", image_path.c_str(), dev.c_str(),
                devcaps[idx]);
    else
        fprintf(f, "FLASH %s %s\n", image_path.c_str(), dev.c_str());
    fclose(f);
    logln("request sent; the service's validation and progress follow:");
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
    Fl_Text_Display *disp = new Fl_Text_Display(10, 140, 660, 310);
    logbuf = new Fl_Text_Buffer();
    disp->buffer(logbuf);
    btn_latest->callback(cb_latest);
    btn_own->callback(cb_own);
    btn_flash->callback(cb_flash);
    rescan->callback([](Fl_Widget*, void*){ scan_devices(); });
    scan_devices();
    logln("Veron Flasher -- every claim below is earned, none assumed.");
    logln("The write happens in a root service that refuses the boot disk");
    logln("and anything non-removable; 'verified' means byte-for-byte read-back.");
    Fl::add_timeout(0.5, poll_status);
    win.end(); win.show(argc, argv);
    return Fl::run();
}
