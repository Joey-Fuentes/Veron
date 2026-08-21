/* veron-boot -- Veron's one-shot maintenance chainloader.
 *
 * WHY THIS EXISTS. Veron boots EFI-stub: the kernel is the EFI executable the
 * firmware loads. Maintenance mode needs a SINGLE boot with a different kernel
 * command line (init=/usr/bin/veron-maintenance-init ...), then normal boots
 * again. The obvious lever -- clone the firmware's current boot entry, change
 * its command line, set BootNext -- does not work across firmware: a machine
 * booted from the removable \EFI\BOOT\BOOTX64.EFI fallback has a BootCurrent
 * that names a transient entry the UEFI spec forbids persisting, so there is
 * nothing to clone, and some firmware never forwards an entry's OptionalData to
 * the stub anyway. Every serious boot manager (systemd-boot, GRUB) therefore
 * keeps its one-shot state in a FILE it controls, not in vendor NVRAM.
 *
 * SO THIS LOADER OWNS THE ONE-SHOT. It installs as \EFI\BOOT\BOOTX64.EFI (and
 * the firmware always runs that on the fallback path, on every machine). On
 * start it looks on the ESP for a marker file \EFI\veron\once.cmdline. If it is
 * there, the loader reads the maintenance command line from it, DELETES the
 * marker (so the override is inherently one-shot -- it is gone before the next
 * boot, even if this boot later fails), and chainloads the real kernel with
 * that command line. If the marker is absent, it chainloads the kernel with no
 * override and the kernel uses its baked-in CONFIG_CMDLINE -- the normal boot.
 *
 * THE KERNEL is at \EFI\veron\A\linux.efi (slot A, the committed slot; A/B
 * selection can grow a marker of its own later). We load it by reading the file
 * into memory and handing the buffer to LoadImage, which avoids constructing an
 * EFI device path for the kernel -- the one genuinely fiddly bit -- and works
 * the same regardless of how we ourselves were booted.
 *
 * FLOW: LoadedImage(self) -> ESP filesystem -> read+delete once.cmdline ->
 * read kernel into pool -> LoadImage(SourceBuffer) -> set child LoadOptions ->
 * StartImage. Freestanding, PE/COFF, MS ABI; no gnu-efi, no libc.
 */
#include "efi.h"

static EFI_SYSTEM_TABLE       *ST;
static EFI_BOOT_SERVICES       *BS;
static EFI_HANDLE               SELF;

static EFI_GUID GUID_LOADED_IMAGE = EFI_LOADED_IMAGE_PROTOCOL_GUID;
static EFI_GUID GUID_SFS          = EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID;
static EFI_GUID GUID_FILE_INFO    = EFI_FILE_INFO_ID;

#define KERNEL_PATH L"\\EFI\\veron\\A\\linux.efi"
#define MARKER_PATH L"\\EFI\\veron\\once.cmdline"

static void say(CHAR16 *s) { if (ST && ST->ConOut) ST->ConOut->OutputString(ST->ConOut, s); }

/* Open the ESP root filesystem we booted from (via our own LoadedImage). */
static EFI_STATUS open_esp_root(EFI_FILE_PROTOCOL **root)
{
    EFI_LOADED_IMAGE_PROTOCOL *li;
    EFI_STATUS s = BS->HandleProtocol(SELF, &GUID_LOADED_IMAGE, (VOID **)&li);
    if (EFI_ERROR(s)) return s;
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *fs;
    s = BS->HandleProtocol(li->DeviceHandle, &GUID_SFS, (VOID **)&fs);
    if (EFI_ERROR(s)) return s;
    return fs->OpenVolume(fs, root);
}

/* Read an entire file into pool memory. Returns buffer+size; caller frees. */
static EFI_STATUS read_file(EFI_FILE_PROTOCOL *root, CHAR16 *path,
                            VOID **out, UINTN *outlen)
{
    EFI_FILE_PROTOCOL *f;
    EFI_STATUS s = root->Open(root, &f, path, EFI_FILE_MODE_READ, 0);
    if (EFI_ERROR(s)) return s;

    /* size via GetInfo(EFI_FILE_INFO) */
    UINT8 infobuf[sizeof(EFI_FILE_INFO) + 256];
    UINTN infolen = sizeof infobuf;
    s = f->GetInfo(f, &GUID_FILE_INFO, &infolen, infobuf);
    if (EFI_ERROR(s)) { f->Close(f); return s; }
    UINT64 size = ((EFI_FILE_INFO *)infobuf)->FileSize;

    VOID *buf;
    s = BS->AllocatePool(EFI_LOADER_DATA, (UINTN)size, &buf);
    if (EFI_ERROR(s)) { f->Close(f); return s; }
    UINTN want = (UINTN)size;
    s = f->Read(f, &want, buf);
    f->Close(f);
    if (EFI_ERROR(s)) { BS->FreePool(buf); return s; }
    *out = buf; *outlen = want;
    return EFI_SUCCESS;
}

/* Read the marker if present, then delete it (one-shot). On success returns the
 * command line as a freshly allocated NUL-terminated UTF-16 string in *cmd16.
 * The marker's bytes are UTF-8 (ASCII in practice for a kernel cmdline); we
 * widen byte-by-byte, which is correct for the ASCII a cmdline contains. */
static EFI_STATUS take_marker(EFI_FILE_PROTOCOL *root, CHAR16 **cmd16, UINTN *bytes16)
{
    EFI_FILE_PROTOCOL *f;
    EFI_STATUS s = root->Open(root, &f, MARKER_PATH, EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE, 0);
    if (EFI_ERROR(s)) return s;                 /* absent -> normal boot */

    UINT8 info[sizeof(EFI_FILE_INFO) + 256];
    UINTN il = sizeof info;
    s = f->GetInfo(f, &GUID_FILE_INFO, &il, info);
    if (EFI_ERROR(s)) { f->Close(f); return s; }
    UINTN n = (UINTN)((EFI_FILE_INFO *)info)->FileSize;

    VOID *raw = 0;
    if (n) {
        s = BS->AllocatePool(EFI_LOADER_DATA, n, &raw);
        if (EFI_ERROR(s)) { f->Close(f); return s; }
        UINTN want = n;
        s = f->Read(f, &want, raw);
        if (EFI_ERROR(s)) { BS->FreePool(raw); f->Close(f); return s; }
        n = want;
    }

    /* delete the marker NOW -- one-shot even if the boot that follows fails.
     * Delete() closes the handle as part of removing the file. */
    f->Delete(f);

    /* trim a trailing newline/CR the writer may have left */
    UINT8 *b = raw;
    while (n && (b[n-1] == '\n' || b[n-1] == '\r' || b[n-1] == 0)) n--;

    /* widen UTF-8/ASCII -> UTF-16, NUL-terminate */
    CHAR16 *w;
    s = BS->AllocatePool(EFI_LOADER_DATA, (n + 1) * sizeof(CHAR16), (VOID **)&w);
    if (EFI_ERROR(s)) { if (raw) BS->FreePool(raw); return s; }
    for (UINTN i = 0; i < n; i++) w[i] = (CHAR16)b[i];
    w[n] = 0;
    if (raw) BS->FreePool(raw);
    *cmd16 = w;
    *bytes16 = (n + 1) * sizeof(CHAR16);         /* include the NUL */
    return EFI_SUCCESS;
}

EFI_STATUS EFIAPI efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st)
{
    ST = st; BS = st->BootServices; SELF = image;

    say(L"veron-boot: starting\r\n");

    EFI_FILE_PROTOCOL *root;
    if (EFI_ERROR(open_esp_root(&root))) {
        say(L"veron-boot: cannot open the ESP -- halting\r\n");
        return EFI_LOAD_ERROR;
    }

    /* one-shot maintenance command line, if armed */
    CHAR16 *cmd = 0; UINTN cmdbytes = 0;
    if (take_marker(root, &cmd, &cmdbytes) == EFI_SUCCESS && cmd)
        say(L"veron-boot: maintenance command line armed (one-shot)\r\n");
    else
        say(L"veron-boot: normal boot\r\n");

    /* read the kernel into memory */
    VOID *kbuf; UINTN klen;
    if (EFI_ERROR(read_file(root, KERNEL_PATH, &kbuf, &klen))) {
        say(L"veron-boot: cannot read the kernel -- halting\r\n");
        return EFI_LOAD_ERROR;
    }

    /* LoadImage from the in-memory kernel (no device path to construct) */
    EFI_HANDLE kimg;
    EFI_STATUS s = BS->LoadImage(0, SELF, 0, kbuf, klen, &kimg);
    if (EFI_ERROR(s)) { say(L"veron-boot: LoadImage failed -- halting\r\n"); return s; }

    /* hand the command line to the kernel via its LoadedImage, if we have one */
    if (cmd) {
        EFI_LOADED_IMAGE_PROTOCOL *kli;
        if (!EFI_ERROR(BS->HandleProtocol(kimg, &GUID_LOADED_IMAGE, (VOID **)&kli))) {
            kli->LoadOptions = cmd;
            kli->LoadOptionsSize = (UINT32)cmdbytes;
        }
    }

    say(L"veron-boot: starting the kernel\r\n");
    s = BS->StartImage(kimg, 0, 0);
    /* only reached if the kernel exits */
    say(L"veron-boot: the kernel returned -- halting\r\n");
    return s;
}
