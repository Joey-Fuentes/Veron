/* veron-pinentry -- what gpg-agent asks when it needs a passphrase or a PIN.
 *
 * WHY THIS EXISTS AT ALL. gnupg is built with
 * --with-pinentry-pgm=/usr/bin/veron-pinentry, so gpg-agent runs this and
 * nothing else. Without it every operation that needs a secret fails: `pass
 * show` cannot decrypt, `pass insert` cannot encrypt to a passphrase-protected
 * key, and a smartcard cannot be asked for its PIN. The vault is installed and
 * unusable until this program answers.
 *
 * IT IS NOT A PLUGIN AND LINKS NOTHING OF gnupg's. A pinentry is an ordinary
 * program that speaks the Assuan protocol on stdin and stdout. gpg-agent
 * spawns it, sends commands one per line, and reads one response per command.
 * That is the whole contract, which is what makes a replacement possible
 * without patching gnupg.
 *
 * THE PROTOCOL, AS gpg-agent ACTUALLY USES IT. Read out of
 * agent/call-pinentry.c in gnupg 2.5.21 rather than remembered:
 *
 *   greeting          we speak first: `OK <anything>`
 *   SET<THING> <text> description, prompt, button labels, error text
 *   OPTION <k>[=<v>]  ttyname, lc-ctype, grab, and a dozen more
 *   GETINFO <what>    flavor, version, pid, ttyinfo
 *   GETPIN            the one that matters: reply `D <secret>` then `OK`
 *   CONFIRM           a yes/no box; `OK` for yes, an error for no
 *   MESSAGE           show text, one button
 *   RESET             forget the per-request state
 *   BYE               reply `OK` and exit
 *
 * AN UNKNOWN COMMAND MUST NOT BE AN ERROR. gpg-agent sends options this
 * program has no use for -- allow-emacs-prompt, formatted-passphrase,
 * constraints-enforce -- and a pinentry that answers ERR to those is one
 * gpg-agent may give up on. Anything unrecognised gets OK. GETINFO is the
 * documented exception: call-pinentry.c:672 substitutes "unknown" when it
 * fails, so a wrong answer there is harmless either way.
 *
 * PASSWORDLESS IS THE POINT, AND THIS IS WHERE IT IS DECIDED. Veron has no
 * passwords anywhere except inside the vault, for legacy websites that demand
 * them. The vault's own key must therefore be unlocked by something you HAVE
 * rather than something you remember. When a key file is configured this
 * derives the passphrase from its bytes and never prompts at all; the typed
 * box below is the fallback for a machine that has not been set up yet, and
 * for the smartcard PIN, which is a device-bound number rather than a
 * password.
 */
#include <FL/Fl.H>
#include <FL/Fl_Window.H>
#include <FL/Fl_Box.H>
#include <FL/Fl_Secret_Input.H>
#include <FL/Fl_Button.H>
#include <FL/Fl_Return_Button.H>

#include <gcrypt.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

/* GPG_ERR_SOURCE_PINENTRY IS 5 AND GPG_ERR_CANCELED IS 99, and the wire wants
 * the packed form: (source << 24) | code. 83886179 is that number and it is
 * what every other pinentry sends; gpg-agent matches on it to tell "the user
 * said no" apart from "the pinentry broke". */
#define ERR_CANCELED "ERR 83886179 Operation cancelled"

static char g_desc[2048];
static char g_prompt[256];
static char g_error[512];
static char g_ok[64];
static char g_cancel[64];
static char g_result[1024];
static char g_repeat[128];        /* SETREPEAT's label; empty means no repeat */
static char g_repeat_err[256];    /* SETREPEATERROR's text                    */
static int  g_confirmed;

/* ---- Assuan line coding ---------------------------------------------- */

/* PERCENT-DECODING IS NOT OPTIONAL. A description containing a newline
 * arrives as %0A, and a literal percent as %25. Displaying the raw form puts
 * "%0A" in a dialog; worse, failing to decode a passphrase constraint string
 * changes what the user is told. */
static void unescape(char *s)
{
    char *r = s, *w = s;
    while (*r) {
        if (r[0] == '%' && r[1] && r[2]) {
            int hi = r[1], lo = r[2];
            hi = hi >= 'a' ? hi - 'a' + 10 : hi >= 'A' ? hi - 'A' + 10 : hi - '0';
            lo = lo >= 'a' ? lo - 'a' + 10 : lo >= 'A' ? lo - 'A' + 10 : lo - '0';
            if (hi >= 0 && hi < 16 && lo >= 0 && lo < 16) {
                *w++ = (char)(hi * 16 + lo);
                r += 3;
                continue;
            }
        }
        *w++ = *r++;
    }
    *w = '\0';
}

/* AND ENCODING ON THE WAY OUT, FOR THE SAME REASON IN REVERSE. A passphrase
 * may legitimately contain a percent or a newline; sent raw, the first would
 * be read as an escape and the second would end the data line early, handing
 * gpg-agent a truncated secret that fails to decrypt with no explanation. */
static void send_data(const char *s)
{
    fputs("D ", stdout);
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (*p == '%' || *p == '\r' || *p == '\n')
            printf("%%%02X", *p);
        else
            fputc(*p, stdout);
    }
    fputs("\n", stdout);
}

static void reply(const char *s)
{
    fputs(s, stdout);
    fputs("\n", stdout);
    fflush(stdout);
}

/* ---- the key file, and the passphrase derived from it ----------------- */

/* THE DERIVATION MUST BE DETERMINISTIC OR THE VAULT IS LOST. The same key
 * file has to produce the same passphrase on every boot, on every machine,
 * for the life of the store -- there is no recovery from a KDF whose
 * parameters drift. Every input is fixed in this source rather than read from
 * configuration: change any of them and existing vaults stop opening.
 *
 * ITERSALTED_S2K RATHER THAN ARGON2, BECAUSE IT IS WHAT THIS API CAN DO.
 * gcry_kdf_derive takes (algo, subalgo, salt, saltlen, iterations, keysize,
 * out) and nothing more -- there is no room for Argon2's time, memory and
 * lane parameters, which is exactly why libgcrypt exposes Argon2 through
 * gcry_kdf_open/compute/final instead. Passing GCRY_KDF_ARGON2 here does not
 * produce a weak Argon2; it fails. The signature was read out of a real call
 * in gnupg's own g10/card-util.c:2138 rather than remembered.
 *
 * WHICH PUTS THE SECURITY ON THE KEY FILE'S ENTROPY, WHERE IT BELONGS. A
 * memory-hard KDF exists to make a GUESSABLE input expensive to guess. A key
 * file is not guessable if it is what it should be: 32 or more bytes from the
 * kernel's random source, on a device you carry. Point this at a photograph
 * instead and no KDF available here will save it -- worth saying plainly
 * rather than implying a stronger KDF would have.
 *
 *     head -c 64 /dev/urandom > /path/to/keyfile
 *
 * THE SALT IS FIXED AND THAT IS DELIBERATE. A random salt would have to be
 * stored beside the key file, adding a thing to lose without adding cost
 * against a specific target. What it gives up is cross-vault rainbow
 * resistance, which a single-user machine is not defending against. */
static int derive_from_keyfile(const char *path, char *out, size_t outlen)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        return 0;
    unsigned char buf[65536];
    size_t n = fread(buf, 1, sizeof buf, f);
    fclose(f);
    if (!n)
        return 0;

    /* EIGHT BYTES, WRITTEN OUT RATHER THAN AS A STRING. "veronpe1" is nine
     * bytes with its terminator and the compiler said so; silencing that with
     * a larger array would have changed the salt and broken every vault
     * derived before the change. */
    static const unsigned char salt[8] =
        { 0x76, 0x65, 0x72, 0x6f, 0x6e, 0x70, 0x65, 0x31 };
    unsigned char key[32];

    gcry_error_t e = gcry_kdf_derive(buf, n,
                                     GCRY_KDF_ITERSALTED_S2K, GCRY_MD_SHA256,
                                     salt, sizeof salt,
                                     1000000, sizeof key, key);
    /* WIPED WHETHER OR NOT THE KDF SUCCEEDED. A key file's bytes are as
     * sensitive as the passphrase they produce. */
    memset(buf, 0, sizeof buf);
    if (e)
        return 0;

    static const char b64[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t w = 0;
    for (size_t i = 0; i < sizeof key && w + 4 < outlen; i += 3) {
        unsigned v = (unsigned)key[i] << 16;
        if (i + 1 < sizeof key) v |= (unsigned)key[i + 1] << 8;
        if (i + 2 < sizeof key) v |= (unsigned)key[i + 2];
        out[w++] = b64[(v >> 18) & 63];
        out[w++] = b64[(v >> 12) & 63];
        out[w++] = (i + 1 < sizeof key) ? b64[(v >> 6) & 63] : '=';
        out[w++] = (i + 2 < sizeof key) ? b64[v & 63] : '=';
    }
    out[w] = '\0';
    memset(key, 0, sizeof key);
    return 1;
}


/* THE CONFIGURED KEY FILE, OR NONE. One key = value per line, so the file can
 * grow a yubikey= and a totp= without changing this parser. */
static int configured_keyfile(char *out, size_t outlen)
{
    const char *home = getenv("HOME");
    if (!home)
        return 0;
    char path[1024];
    snprintf(path, sizeof path, "%s/.config/veron/pinentry.conf", home);
    FILE *f = fopen(path, "r");
    if (!f)
        return 0;
    char line[1024];
    int found = 0;
    while (fgets(line, sizeof line, f)) {
        char *nl = strpbrk(line, "\r\n");
        if (nl) *nl = '\0';
        if (!strncmp(line, "keyfile=", 8) && line[8]) {
            snprintf(out, outlen, "%s", line + 8);
            found = 1;
            break;
        }
    }
    fclose(f);
    return found;
}

/* ---- the dialog ------------------------------------------------------- */

static Fl_Secret_Input *g_input;
static Fl_Window *g_win;
static int g_ok_pressed;

static void on_ok(Fl_Widget *, void *)   { g_ok_pressed = 1; g_win->hide(); }
static void on_cancel(Fl_Widget *, void *) { g_ok_pressed = 0; g_win->hide(); }

/* A WINDOW PER REQUEST, NOT A REUSED ONE. gpg-agent may ask several times in
 * one session -- a wrong passphrase is a second GETPIN with SETERROR set --
 * and a window carrying the previous attempt's text is how a stale error ends
 * up shown beside a fresh prompt. */
static int ask(int secret)
{
    g_ok_pressed = 0;
    Fl_Window win(420, secret ? 190 : 150, "Veron");
    g_win = &win;

    int y = 12;
    if (g_error[0]) {
        Fl_Box *e = new Fl_Box(12, y, 396, 24, g_error);
        e->align(FL_ALIGN_LEFT | FL_ALIGN_INSIDE | FL_ALIGN_WRAP);
        e->labelcolor(FL_RED);
        y += 28;
    }
    Fl_Box *d = new Fl_Box(12, y, 396, 48,
                           g_desc[0] ? g_desc : "Authentication required");
    d->align(FL_ALIGN_LEFT | FL_ALIGN_INSIDE | FL_ALIGN_WRAP);
    y += 52;

    if (secret) {
        Fl_Secret_Input *in = new Fl_Secret_Input(
            12 + 90, y, 306, 26, g_prompt[0] ? g_prompt : "Passphrase:");
        g_input = in;
        y += 34;
    }

    Fl_Button *cancel = new Fl_Button(12, y, 110, 28,
                                      g_cancel[0] ? g_cancel : "Cancel");
    cancel->callback(on_cancel);
    Fl_Return_Button *okb = new Fl_Return_Button(
        298, y, 110, 28, g_ok[0] ? g_ok : "OK");
    okb->callback(on_ok);

    win.end();
    win.set_modal();
    win.show();
    if (secret && g_input)
        g_input->take_focus();
    while (win.shown())
        Fl::wait();
    return g_ok_pressed;
}

/* ---- the command loop -------------------------------------------------- */

static int starts(const char *line, const char *cmd, const char **rest)
{
    size_t n = strlen(cmd);
    if (strncmp(line, cmd, n))
        return 0;
    if (line[n] && line[n] != ' ')
        return 0;
    *rest = line[n] ? line + n + 1 : line + n;
    return 1;
}

int main(int argc, char **argv)
{
    /* --version AND --help ARE ASKED BY PACKAGING AND BY PEOPLE, and a
     * pinentry that opens a window in answer is a pinentry that hangs a build
     * log. Answered before anything else touches stdin. */
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--version")) {
            printf("veron-pinentry 1.0\n");
            return 0;
        }
        if (!strcmp(argv[i], "--help")) {
            printf("veron-pinentry: an Assuan pinentry for gpg-agent.\n"
                   "Not run by hand; gpg-agent spawns it.\n");
            return 0;
        }
    }

    gcry_check_version(NULL);
    gcry_control(GCRYCTL_INITIALIZATION_FINISHED, 0);

    /* THE GREETING COMES FIRST AND UNPROMPTED. gpg-agent waits for it before
     * sending anything, so a pinentry that reads before it writes deadlocks
     * against an agent that writes only after it reads. */
    reply("OK Veron pinentry ready");

    char line[4096];
    while (fgets(line, sizeof line, stdin)) {
        char *nl = strpbrk(line, "\r\n");
        if (nl) *nl = '\0';
        const char *rest;

        if (starts(line, "BYE", &rest)) {
            reply("OK closing connection");
            break;
        }
        if (starts(line, "RESET", &rest)) {
            g_error[0] = g_result[0] = '\0';
            /* THE REPEAT IS PER REQUEST. Left set, the next ordinary unlock --
             * which has no SETREPEAT -- would ask for the passphrase twice and
             * send a PIN_REPEATED nobody asked for. */
            g_repeat[0] = g_repeat_err[0] = '\0';
            g_confirmed = 0;
            reply("OK");
            continue;
        }
        if (starts(line, "SETDESC", &rest)) {
            snprintf(g_desc, sizeof g_desc, "%s", rest);
            unescape(g_desc);
            reply("OK");
            continue;
        }
        if (starts(line, "SETPROMPT", &rest)) {
            snprintf(g_prompt, sizeof g_prompt, "%s", rest);
            unescape(g_prompt);
            reply("OK");
            continue;
        }
        if (starts(line, "SETERROR", &rest)) {
            snprintf(g_error, sizeof g_error, "%s", rest);
            unescape(g_error);
            reply("OK");
            continue;
        }
        if (starts(line, "SETOK", &rest)) {
            snprintf(g_ok, sizeof g_ok, "%s", rest);
            unescape(g_ok);
            reply("OK");
            continue;
        }
        if (starts(line, "SETCANCEL", &rest) || starts(line, "SETNOTOK", &rest)) {
            snprintf(g_cancel, sizeof g_cancel, "%s", rest);
            unescape(g_cancel);
            reply("OK");
            continue;
        }
        /* SETREPEAT IS A CAPABILITY CLAIM, NOT AN ACKNOWLEDGEMENT, AND
         * ANSWERING OK WITHOUT MEANING IT BREAKS EVERY NEW PASSPHRASE.
         *
         * call-pinentry.c:1573 sends SETREPEAT when a passphrase is being
         * SET rather than merely entered, and :1630 then accepts the result
         * only if the pinentry reported `S PIN_REPEATED`. Answering OK says
         * "I will ask twice and check"; not sending the status afterwards
         * says "they did not match". So a pinentry that treats SETREPEAT as
         * just another unknown option rejects every passphrase the user
         * types, forever, with `Bad Passphrase (try 2 of 3)` and no way
         * through -- which is exactly what it did.
         *
         * The blanket OK for unrecognised commands is still right; this is
         * the case where OK is a promise rather than a receipt. */
        if (starts(line, "SETREPEAT", &rest)) {
            snprintf(g_repeat, sizeof g_repeat, "%s", rest);
            unescape(g_repeat);
            if (!g_repeat[0])
                snprintf(g_repeat, sizeof g_repeat, "Repeat:");
            reply("OK");
            continue;
        }
        if (starts(line, "SETREPEATERROR", &rest)) {
            snprintf(g_repeat_err, sizeof g_repeat_err, "%s", rest);
            unescape(g_repeat_err);
            reply("OK");
            continue;
        }
        if (starts(line, "SETREPEATOK", &rest)) {
            reply("OK");
            continue;
        }
        if (starts(line, "GETINFO", &rest)) {
            if (!strcmp(rest, "flavor"))       send_data("veron");
            else if (!strcmp(rest, "version")) send_data("1.0");
            else if (!strcmp(rest, "pid")) {
                char b[32];
                snprintf(b, sizeof b, "%ld", (long)getpid());
                send_data(b);
            }
            reply("OK");
            continue;
        }
        if (starts(line, "MESSAGE", &rest)) {
            ask(0);
            reply("OK");
            continue;
        }
        if (starts(line, "CONFIRM", &rest)) {
            /* --one-button IS A NOTICE, NOT A QUESTION. There is nothing to
             * decline, so the only honest answer is OK. */
            if (strstr(line, "--one-button")) {
                ask(0);
                reply("OK");
            } else {
                reply(ask(0) ? "OK" : ERR_CANCELED);
            }
            continue;
        }
        if (starts(line, "GETPIN", &rest)) {
            char kf[1024], derived[128];
            /* THE KEY FILE PATH IS TAKEN AS A SECRET-BEARING INPUT, so a
             * missing or unreadable file falls through to the prompt rather
             * than failing: a machine whose USB key is not plugged in should
             * ask, not refuse. */
            if (configured_keyfile(kf, sizeof kf) &&
                derive_from_keyfile(kf, derived, sizeof derived)) {
                send_data(derived);
                memset(derived, 0, sizeof derived);
                reply("OK");
                continue;
            }
            if (!ask(1)) {
                reply(ERR_CANCELED);
                continue;
            }
            char first[1024];
            snprintf(first, sizeof first, "%s",
                     g_input && g_input->value() ? g_input->value() : "");

            /* THE REPEAT, WHEN ONE WAS ASKED FOR. Prompt a second time, compare,
             * and say so with `S PIN_REPEATED` -- which is the status
             * call-pinentry.c:1630 checks before it will accept the passphrase
             * at all. A mismatch re-prompts rather than failing outright,
             * because gpg-agent counts a failure against its three tries and a
             * typo in the confirmation is not a wrong passphrase. */
            if (g_repeat[0]) {
                for (;;) {
                    char save_prompt[256];
                    snprintf(save_prompt, sizeof save_prompt, "%s", g_prompt);
                    snprintf(g_prompt, sizeof g_prompt, "%s", g_repeat);

                    int got = ask(1);
                    char again[1024];
                    snprintf(again, sizeof again, "%s",
                             g_input && g_input->value() ? g_input->value() : "");
                    snprintf(g_prompt, sizeof g_prompt, "%s", save_prompt);

                    if (!got) {
                        explicit_bzero(first, sizeof first);
                        explicit_bzero(again, sizeof again);
                        reply(ERR_CANCELED);
                        goto next_command;
                    }
                    if (!strcmp(first, again)) {
                        explicit_bzero(again, sizeof again);
                        /* THE STATUS LINE COMES BEFORE THE DATA, as a status
                         * always does: gpg-agent reads status callbacks during
                         * the transaction and the D line ends it. */
                        reply("S PIN_REPEATED");
                        break;
                    }
                    explicit_bzero(again, sizeof again);
                    snprintf(g_error, sizeof g_error, "%s",
                             g_repeat_err[0] ? g_repeat_err
                                             : "The passphrases do not match");
                }
                g_error[0] = '\0';
            }

            send_data(first);
            explicit_bzero(first, sizeof first);
            reply("OK");
            /* THE WIDGET IS GONE BY NOW -- ask() returned and its window went
             * out of scope -- so there is nothing left to wipe here. That is
             * a real limitation of building the dialog on the stack and it is
             * recorded rather than hidden: FLTK's Fl_Input owns its buffer and
             * frees it without zeroing. */
            g_input = NULL;
            continue;
        }
        /* EVERY OTHER COMMAND IS AN OPTION WE DO NOT IMPLEMENT, AND OK IS THE
         * RIGHT ANSWER. See the header: answering ERR to allow-emacs-prompt or
         * formatted-passphrase is how a pinentry gets abandoned by an agent
         * that would otherwise have worked. */
        reply("OK");
        continue;

        /* THE LABEL SITS PAST THE CATCH-ALL, AND THAT PLACEMENT IS THE POINT.
         * Put before it, a cancel during the repeat prompt would jump here,
         * fall into reply("OK"), and send OK immediately after ERR_CANCELED --
         * two responses to one command, which desynchronises the protocol for
         * every request after it. */
    next_command:
        continue;
    }
    return 0;
}
