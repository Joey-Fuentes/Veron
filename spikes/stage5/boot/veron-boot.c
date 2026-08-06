/* veron-boot.c -- the smallest thing that can start a Linux kernel with
 * arguments, so stage 4 can ship ONE generic kernel.
 *
 * WHY THIS EXISTS, MEASURED RATHER THAN ASSUMED.
 *
 * The design said the kernel's EFI stub is the bootloader: put the kernel at
 * \EFI\BOOT\BOOTAA64.EFI and the firmware starts it directly. That half is
 * true and was tested -- edk2 loads it and Linux boots. What is not true is
 * that anything can then CONFIGURE it. The firmware starts the fallback path
 * with empty LoadOptions, a freshly written disk has no NVRAM boot entry to
 * carry arguments, and the stub reads nothing else:
 *
 *     Booting Linux
 *     Kernel panic - not syncing: VFS: Unable to mount root fs on
 *       unknown-block(0,0)
 *
 * A `.cmdline` PE section was the obvious escape and does not work either.
 * That is systemd-stub's convention, and systemd-stub is a separate EFI
 * application that reads it and then loads the kernel. Checked against this
 * exact kernel: the strings ".cmdline", ".initrd" and ".linux" do not appear
 * in the binary at all, and a section lookup by name needs the name to
 * compare against. So the stub takes LoadOptions and nothing else.
 *
 * The alternative was CONFIG_CMDLINE, and that is the wrong place: it welds
 * one root device into the artifact that is supposed to be common to the
 * .img, the ISO and Android's AVF. Three image types, one kernel, three
 * different root filesystems -- the variable part must live in the wrapper,
 * and the wrapper is the ESP.
 *
 * So: a loader that reads a text file, loads a kernel and an optional initrd,
 * and starts the kernel with LoadOptions set. That is the whole job. GRUB
 * does it in a hundred thousand lines because it also parses filesystems,
 * draws menus and boots six operating systems. None of that is wanted here.
 *
 * NO gnu-efi, NO EDK2, NO LIBRARY. The UEFI structures below are transcribed
 * from the specification. It is more lines than including a header, and it is
 * the same choice `veron-image` makes about GPT and FAT32 and `veron rootfs`
 * makes about tar: a from-source distribution that cannot produce its own
 * boot path without someone else's build system has missed its own point.
 *
 * WHAT IT DELIBERATELY DOES NOT DO: no menu, no timeout, no second entry, no
 * signature verification, no chainloading. A menu is a thing to configure and
 * this system has one kernel. Secure Boot verification belongs with a signing
 * story that does not exist yet; adding an unverified check would be theatre.
 */

typedef unsigned short   u16;
typedef unsigned int     u32;
typedef unsigned long    u64;
typedef unsigned long    uintn;
typedef u16              wchar;
typedef u64              status;

#define EFI_SUCCESS      0
#define EFI_ERR          0x8000000000000000UL
#define EFIAPI           /* aarch64 uses the plain AAPCS64 calling convention */

typedef struct { u32 a; u16 b, c; unsigned char d[8]; } guid;

/* The four protocols this needs, and nothing else. */
static const guid LOADED_IMAGE_GUID =
    {0x5B1B31A1,0x9562,0x11d2,{0x8E,0x3F,0x00,0xA0,0xC9,0x69,0x72,0x3B}};
static const guid SIMPLE_FS_GUID =
    {0x964E5B22,0x6459,0x11d2,{0x8E,0x39,0x00,0xA0,0xC9,0x69,0x72,0x3B}};
static const guid FILE_INFO_GUID =
    {0x09576E92,0x6D3F,0x11d2,{0x8E,0x39,0x00,0xA0,0xC9,0x69,0x72,0x3B}};
static const guid LOAD_FILE2_GUID =
    {0x4006c0c1,0xfcb3,0x403e,{0x99,0x6d,0x4a,0x6c,0x87,0x24,0xe0,0x6d}};

struct efi_text_output {
    void *reset;
    status (EFIAPI *output_string)(struct efi_text_output *, wchar *);
};

struct efi_file {
    u64 revision;
    status (EFIAPI *open)(struct efi_file *, struct efi_file **, wchar *,
                          u64 mode, u64 attr);
    status (EFIAPI *close)(struct efi_file *);
    void *del;
    status (EFIAPI *read)(struct efi_file *, uintn *, void *);
    void *write, *get_position, *set_position;
    status (EFIAPI *get_info)(struct efi_file *, const guid *, uintn *, void *);
};

struct efi_simple_fs {
    u64 revision;
    status (EFIAPI *open_volume)(struct efi_simple_fs *, struct efi_file **);
};

struct efi_loaded_image {
    u32 revision, parent_pad;
    void *system_table;
    void *device_handle;
    void *file_path, *reserved;
    u32 load_options_size;
    void *load_options;
    void *image_base;
    u64 image_size;
    u32 image_code_type, image_data_type;
    void *unload;
};

struct efi_boot_services {
    char hdr[24];
    void *raise_tpl, *restore_tpl;
    void *allocate_pages, *free_pages, *get_memory_map;
    status (EFIAPI *allocate_pool)(u32 type, uintn size, void **buf);
    status (EFIAPI *free_pool)(void *buf);
    void *create_event, *set_timer, *wait_for_event, *signal_event,
         *close_event, *check_event;
    status (EFIAPI *install_protocol_interface)(void **handle, const guid *,
                                                u32 type, void *iface);
    void *reinstall_protocol_interface, *uninstall_protocol_interface;
    status (EFIAPI *handle_protocol)(void *handle, const guid *, void **);
    void *reserved, *register_protocol_notify, *locate_handle,
         *locate_device_path, *install_configuration_table;
    status (EFIAPI *load_image)(unsigned char boot_policy, void *parent,
                                void *path, void *src, uintn src_size,
                                void **image);
    status (EFIAPI *start_image)(void *image, uintn *exit_size, wchar **exit);
    void *exit, *unload_image;
    status (EFIAPI *exit_boot_services)(void *image, uintn map_key);
};

struct efi_system_table {
    char hdr[24];
    wchar *firmware_vendor;
    u32 firmware_revision, pad;
    void *console_in_handle, *con_in;
    void *console_out_handle;
    struct efi_text_output *con_out;
    void *stderr_handle, *stderr_out;
    void *runtime_services;
    struct efi_boot_services *boot;
};

/* A device path is a list of typed nodes ending in an END node. The kernel's
 * stub finds an initrd by asking the firmware to locate LOAD_FILE2 on this
 * exact vendor-defined path -- that is the documented interface, and it is
 * why the GUID above is not arbitrary. */
struct dev_path_node { unsigned char type, subtype; u16 length; };
struct initrd_path {
    struct dev_path_node vendor;
    guid                 id;
    struct dev_path_node end;
} __attribute__((packed));

static struct initrd_path initrd_path = {
    { 0x04, 0x03, sizeof(struct dev_path_node) + sizeof(guid) },
    {0x5568e427,0x68fc,0x4f3d,{0xac,0x74,0xca,0x55,0x52,0x31,0xcc,0x68}},
    { 0x7F, 0xFF, sizeof(struct dev_path_node) }
};

struct efi_load_file2 {
    status (EFIAPI *load_file)(struct efi_load_file2 *, void *path,
                               unsigned char boot_policy,
                               uintn *size, void *buf);
};

static struct efi_system_table *ST;
static void *initrd_data;
static uintn initrd_size;

static void print(const wchar *s)
{
    ST->con_out->output_string(ST->con_out, (wchar *)s);
}

/* The initrd is served rather than copied into the kernel's arguments.
 * Linux's stub calls this when it wants one; returning it here is what makes
 * `initrd=` unnecessary and keeps the mechanism independent of the command
 * line entirely. */
static status EFIAPI serve_initrd(struct efi_load_file2 *self, void *path,
                                  unsigned char policy, uintn *size, void *buf)
{
    (void)self; (void)path; (void)policy;
    if (!size) return EFI_ERR | 2;
    if (!buf || *size < initrd_size) { *size = initrd_size; return EFI_ERR | 5; }
    for (uintn i = 0; i < initrd_size; i++)
        ((unsigned char *)buf)[i] = ((unsigned char *)initrd_data)[i];
    *size = initrd_size;
    return EFI_SUCCESS;
}

/* FILLED IN AT RUN TIME, NOT AT LINK TIME, AND THAT IS THE WHOLE REASON.
 *
 * `= { serve_initrd }` is a function address in a static initialiser, which
 * the linker cannot resolve until the image is loaded -- so it emits a
 * relocation. It was the ONLY one in the program, and it was enough to make
 * the PE either need a .reloc section or be marked RELOCS_STRIPPED with
 * ImageBase=0, which is "load me at address zero", which firmware refuses.
 *
 * Assigning it inside efi_main costs one instruction and leaves an image with
 * no relocations at all -- which can honestly claim RELOCS_STRIPPED and be
 * loaded anywhere, because there is nothing in it that depends on where. */
static struct efi_load_file2 initrd_protocol;

/* Read a whole file from the volume this loader was started from. Returns 0
 * and leaves *out untouched when the file is absent, because a missing initrd
 * is a configuration, not a failure. */
static int read_file(struct efi_file *root, wchar *name, void **out, uintn *len)
{
    struct efi_file *f;
    if (root->open(root, &f, name, 1, 0) != EFI_SUCCESS) return 0;

    unsigned char info[512];
    uintn isz = sizeof info;
    if (f->get_info(f, &FILE_INFO_GUID, &isz, info) != EFI_SUCCESS) {
        f->close(f);
        return 0;
    }
    /* EFI_FILE_INFO: Size, FileSize, PhysicalSize, ... -- FileSize is at 8. */
    u64 size = *(u64 *)(info + 8);
    if (!size) { f->close(f); return 0; }

    void *buf;
    if (ST->boot->allocate_pool(2 /* LoaderData */, size, &buf) != EFI_SUCCESS) {
        f->close(f);
        return 0;
    }
    uintn want = size;
    if (f->read(f, &want, buf) != EFI_SUCCESS) {
        ST->boot->free_pool(buf);
        f->close(f);
        return 0;
    }
    f->close(f);
    *out = buf;
    *len = want;
    return 1;
}

/* The command line is UTF-8 on disk and UTF-16 in LoadOptions. Only the
 * ASCII range is handled, deliberately: a kernel command line that needs
 * anything else is a command line worth rejecting. Trailing newlines and
 * carriage returns are dropped so the file can be edited by anything. */
static void to_utf16(unsigned char *in, uintn n, wchar *out, uintn max)
{
    uintn j = 0;
    for (uintn i = 0; i < n && j + 1 < max; i++) {
        if (in[i] == '\n' || in[i] == '\r') continue;
        out[j++] = (wchar)in[i];
    }
    out[j] = 0;
}

status EFIAPI efi_main(void *image_handle, struct efi_system_table *st)
{
    ST = st;
    initrd_protocol.load_file = serve_initrd;   /* see the note above */
    print(L"veron-boot\r\n");

    struct efi_loaded_image *li;
    if (st->boot->handle_protocol(image_handle, &LOADED_IMAGE_GUID,
                                  (void **)&li) != EFI_SUCCESS) {
        print(L"  no loaded-image protocol\r\n");
        return EFI_ERR | 1;
    }

    struct efi_simple_fs *fs;
    if (st->boot->handle_protocol(li->device_handle, &SIMPLE_FS_GUID,
                                  (void **)&fs) != EFI_SUCCESS) {
        print(L"  no filesystem on the boot device\r\n");
        return EFI_ERR | 1;
    }

    struct efi_file *root;
    if (fs->open_volume(fs, &root) != EFI_SUCCESS) {
        print(L"  cannot open the volume\r\n");
        return EFI_ERR | 1;
    }

    /* THE CONFIGURATION, AND THE ONLY THING THAT DIFFERS BETWEEN IMAGE TYPES.
     * The .img writes root=PARTUUID=..., an ISO writes something else, and a
     * VM can write whatever it likes -- all three around the same kernel. */
    void *cl_raw = 0;
    uintn cl_len = 0;
    static wchar cmdline[1024];
    if (read_file(root, L"\\EFI\\veron\\cmdline", &cl_raw, &cl_len)) {
        to_utf16(cl_raw, cl_len, cmdline, 1024);
        print(L"  cmdline: ");
        print(cmdline);
        print(L"\r\n");
    } else {
        print(L"  no \\EFI\\veron\\cmdline -- the kernel will get none\r\n");
        cmdline[0] = 0;
    }

    /* The initrd is OPTIONAL. A kernel that can mount its root directly does
     * not need one, and saying so is cheaper than pretending it is required. */
    if (read_file(root, L"\\EFI\\veron\\initrd", &initrd_data, &initrd_size)) {
        void *handle = 0;
        if (st->boot->install_protocol_interface(
                &handle, &LOAD_FILE2_GUID, 0, &initrd_protocol) == EFI_SUCCESS) {
            /* The device path must be installed on the same handle, or the
             * kernel's stub will not find it. */
            static const guid DEVICE_PATH_GUID =
                {0x09576e91,0x6d3f,0x11d2,
                 {0x8e,0x39,0x00,0xa0,0xc9,0x69,0x72,0x3b}};
            st->boot->install_protocol_interface(&handle, &DEVICE_PATH_GUID,
                                                 0, &initrd_path);
            print(L"  initrd: served over LoadFile2\r\n");
        }
    } else {
        print(L"  no \\EFI\\veron\\initrd -- booting without one\r\n");
    }

    void *kbuf = 0;
    uintn ksize = 0;
    if (!read_file(root, L"\\EFI\\veron\\linux", &kbuf, &ksize)) {
        print(L"  no \\EFI\\veron\\linux -- nothing to boot\r\n");
        return EFI_ERR | 14;
    }

    void *kernel = 0;
    if (st->boot->load_image(0, image_handle, 0, kbuf, ksize, &kernel)
            != EFI_SUCCESS) {
        print(L"  the kernel is not a loadable EFI image\r\n");
        return EFI_ERR | 1;
    }

    /* THE POINT OF THE WHOLE PROGRAM IS THESE THREE LINES. Everything above
     * exists so that LoadOptions is not empty when the stub runs. */
    struct efi_loaded_image *kli;
    if (st->boot->handle_protocol(kernel, &LOADED_IMAGE_GUID,
                                  (void **)&kli) == EFI_SUCCESS) {
        uintn n = 0;
        while (cmdline[n]) n++;
        kli->load_options = cmdline;
        kli->load_options_size = (u32)((n + 1) * sizeof(wchar));
    }

    print(L"  starting the kernel\r\n");
    uintn exit_size = 0;
    wchar *exit_data = 0;
    return st->boot->start_image(kernel, &exit_size, &exit_data);
}
