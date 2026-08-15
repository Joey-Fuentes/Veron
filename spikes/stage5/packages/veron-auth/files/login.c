/* veron-login -- the gate in front of a console shell.
 *
 * IT DOES NOT CHANGE WHO YOU ARE, AND THAT IS THE WHOLE REASON IT IS SMALL.
 * The console service already runs as `veron` -- `run-as = veron` in the dinit
 * file -- so getty, this program and the shell it execs are all the same
 * unprivileged user. There is no setuid, no setgid, no supplementary-group
 * juggling and none of the ordering hazards that make a real `login` risky to
 * write. This authenticates and then execs; if it were ever moved to a getty
 * running as root, that changes and this program would have to grow the
 * privilege-drop sequence it currently, deliberately, does not have.
 *
 * WHICH MAKES IT A GATE, NOT A SECURITY BOUNDARY, on a machine where the
 * console is already unprivileged. What it buys is that someone at the
 * keyboard cannot simply read the screen and start typing -- the same thing
 * the lock screen buys for the desktop, using the same verifier so the two
 * cannot disagree about what a factor means.
 *
 * IT MUST NOT BE THE ONLY WAY IN WHILE IT IS BEING TESTED. This ships on a
 * spare VT with the existing console left exactly as it was; see the recipe
 * and the console-auth service. A login gate that rejects you on a machine
 * with no other console is a machine you reinstall.
 */
#define _GNU_SOURCE 1
#include "verify.h"

#include <gcrypt.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <termios.h>
#include <time.h>

/* ECHO OFF WHILE A FACTOR IS TYPED. A TOTP code is short-lived and a key file
 * path is not secret, but the same prompt may later carry something that is,
 * and a prompt that echoes by default is one that will eventually echo the
 * wrong thing. Restored on every path out, including the error paths. */
static int read_secret(const char *prompt, char *buf, size_t buflen)
{
    struct termios old, quiet;
    int have_tty = tcgetattr(STDIN_FILENO, &old) == 0;

    fputs(prompt, stdout);
    fflush(stdout);

    if (have_tty) {
        quiet = old;
        quiet.c_lflag &= (unsigned)~ECHO;
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &quiet);
    }

    char *r = fgets(buf, (int)buflen, stdin);

    if (have_tty)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &old);
    fputs("\n", stdout);

    if (!r)
        return 0;
    char *nl = strpbrk(buf, "\r\n");
    if (nl) *nl = '\0';
    return 1;
}

int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++)
        if (!strcmp(argv[i], "--version")) {
            printf("veron-login 1.0\n");
            return 0;
        }

    gcry_check_version(NULL);
    gcry_control(GCRYCTL_INITIALIZATION_FINISHED, 0);

    const char *shell = getenv("SHELL");
    if (!shell || !*shell)
        shell = "/bin/sh";

    /* THREE ATTEMPTS AND THEN EXIT, NOT A LOCKOUT. getty restarts this, so
     * exiting simply produces a fresh prompt -- the delay is what makes
     * guessing slow, and there is nothing here that can refuse forever. The
     * lock screen makes the same argument for the same reason. */
    for (int attempt = 0; attempt < 3; attempt++) {
        char input[512];
        if (!read_secret("veron: ", input, sizeof input)) {
            /* EOF -- getty will start a new session. */
            return 0;
        }

        int ok = veron_verify(input, (int)strlen(input));
        explicit_bzero(input, sizeof input);

        if (ok) {
            /* exec, NOT fork: this process IS the session's shell as far as
             * getty is concerned, and forking would leave a parent doing
             * nothing while the tty's controlling process is the wrong one. */
            execl(shell, shell, "-l", (char *)NULL);
            /* AND IF exec FAILS THE GATE MUST NOT SILENTLY OPEN. */
            perror("veron-login: exec");
            return 1;
        }

        fputs("not accepted\n", stdout);
        struct timespec ts = { 2, 0 };
        nanosleep(&ts, NULL);
    }
    return 1;
}
