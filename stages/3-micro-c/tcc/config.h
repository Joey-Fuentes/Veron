/* stages/3-micro-c/tcc/config.h -- tcc's configuration, WRITTEN, not generated.
 *
 * Upstream's ./configure emits this file by probing the host: the compiler
 * that runs it, the kernel it runs on. The toolbox tarball this build used
 * to carry shipped one such file, made on a GitHub Azure runner (CC_gcc,
 * GCC 13.3, "6.17.0-1020-azure") -- host provenance inside the bootstrap's
 * inputs, and a configure step no chain without a host compiler can rerun.
 *
 * This file has only the values that reach the compiler being built, each
 * a pinned decision (2026-08-25):
 *   TCC_VERSION       the pin's version string, sources/tcc.toml
 *   TCC_TARGET_ARM64  the default target when no -DTCC_TARGET_* is given;
 *                     cross-amd64.sh passes -DTCC_TARGET_X86_64 and the
 *                     guard below stands aside, as upstream's file does
 *   CONFIG_TRIPLET    the include-path triplet for the arm64 default
 *   CONFIG_TCCDIR     where a tcc looks for its libtcc1.a; the chain passes
 *                     -B explicitly and never depends on this default
 *   CONFIG_TCC_PREDEFS  compile tccdefs.h in (tccdefs_.h), upstream default
 * Left out, with the grep that says why: CC_NAME and GCC_MAJOR are read
 * by nothing in the tree; CONFIG_OS_RELEASE feeds only the BSD ABI-tag note
 * (tccelf.c create_bsd_note_section, TARGETOS_FreeBSD/OpenBSD/NetBSD) and
 * is dead on Linux. Same bytes out of the same source, and every value
 * here is one a person chose.
 */
#define TCC_VERSION "0.9.28rc"

#if !(TCC_TARGET_I386 || TCC_TARGET_X86_64 || TCC_TARGET_ARM || TCC_TARGET_ARM64 || TCC_TARGET_RISCV64 || TCC_TARGET_C67)
#define TCC_TARGET_ARM64 1
#define CONFIG_TRIPLET "arm64-linux-gnu"
#endif

#ifndef CONFIG_TCCDIR
#define CONFIG_TCCDIR "/usr/local/lib/tcc"
#endif
#define CONFIG_TCC_PREDEFS 1
