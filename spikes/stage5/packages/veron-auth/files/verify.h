/* The factor verifier, shared by the lock screen and (later) login.
 *
 * THE SPLIT THIS HEADER EXISTS TO ENFORCE. Two different questions get asked
 * of an authentication factor and they are not interchangeable:
 *
 *   GATE   -- "is this factor present and correct?" A yes or no. Enough for a
 *             lock screen and for login, because in both cases the disk is
 *             already unlocked and the secret being compared against is
 *             readable.
 *
 *   DERIVE -- "reconstruct 32 bytes of key material from this factor." What
 *             full-disk encryption needs, because there is no stored secret
 *             to compare against yet: the disk key must come OUT of the
 *             factor.
 *
 * TOTP CAN ONLY GATE, AND THAT IS NOT A LIMITATION OF THIS CODE. Verifying a
 * six-digit code requires already holding the shared seed. Before the disk is
 * unlocked that seed would have to sit in the initramfs in the clear, where
 * anyone with the disk can read it and mint valid codes forever -- so the
 * factor would protect nothing. And six digits is about twenty bits, which is
 * not key material under any circumstances.
 *
 * So there is deliberately no veron_totp_derive() in this header. The absence
 * is the point: FDE links only the _derive functions, and cannot reach a
 * factor that is incapable of the job even by mistake.
 *
 * WHAT THIS FILE DOES NOT DO. It never decides policy -- whether one factor
 * suffices or two are required is the caller's, read from configuration. It
 * only answers about individual factors.
 */
#pragma once

#include <stddef.h>
#include <stdint.h>

/* ---- GATE: yes or no, for the lock screen and login ------------------- */

/* THE ONE ENTRY POINT THE LOCK SCREEN USES. It applies whatever factors are
 * configured in ~/.config/veron/auth.conf to the typed input and returns
 * non-zero only if they are satisfied. `len` is passed explicitly because the
 * input is not necessarily NUL-terminated and must not be treated as a string
 * by accident. */
int veron_verify(const char *input, int len);

/* A SIX-DIGIT CODE AGAINST A STORED SEED. RFC 6238: a 30-second step, one
 * step of drift accepted either side, and -- the part that is usually
 * missing -- the last accepted step is written down so the same code cannot
 * be replayed inside its own window by somebody who read it over a shoulder.
 */
int veron_totp_check(const char *seedpath, const char *statepath,
                     const char *code, int codelen);

/* IS THE CARD THERE. Possession only: this asks the already-running gpg
 * stack for a serial number and does not prove the card can do anything.
 * Enough to gate a screen, not enough to release a disk. */
int veron_card_present(void);

/* ---- DERIVE: key material, for full-disk encryption ------------------- */

/* A KEY FILE'S BYTES, STRETCHED. The output is stable for a given file and
 * salt, which is the whole requirement: the same key file must open the same
 * volume on every boot for the life of the store.
 *
 * NOT YET USED BY ANYTHING IN THIS TREE. It is declared here because the lock
 * screen and the disk unlocker must agree about what a key file means before
 * either of them ships, not afterwards. */
int veron_keyfile_derive(const char *path, const uint8_t salt[16],
                         uint8_t out[32]);
