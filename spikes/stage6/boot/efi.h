/* efi.h -- the minimal slice of UEFI that veron-boot uses. No gnu-efi, no EDK2:
 * just the handful of structs, GUIDs and function-pointer tables this loader
 * calls, transcribed from the UEFI 2.x specification. Kept small on purpose --
 * every field here is one this loader actually touches.
 *
 * Calling convention: UEFI on x86_64 uses the Microsoft ABI. We build with the
 * PE/COFF target so the compiler emits that ABI; the __attribute__((ms_abi)) on
 * the protocol function pointers makes the types match regardless of the host
 * default, which is the belt-and-suspenders gnu-efi does too. */
#ifndef VERON_EFI_H
#define VERON_EFI_H

typedef unsigned char      UINT8;
typedef unsigned short     UINT16;
typedef unsigned int       UINT32;
typedef unsigned long long UINT64;
typedef signed long long   INTN;
typedef unsigned long long UINTN;
typedef unsigned short     CHAR16;
typedef void               VOID;
typedef UINTN              EFI_STATUS;
typedef VOID              *EFI_HANDLE;
typedef VOID              *EFI_EVENT;

#define EFIAPI __attribute__((ms_abi))
#define IN
#define OUT
#define OPTIONAL

/* status codes (high bit set = error, per spec) */
#define EFI_SUCCESS            0x0000000000000000ULL
#define EFI_LOAD_ERROR         0x8000000000000001ULL
#define EFI_INVALID_PARAMETER  0x8000000000000002ULL
#define EFI_UNSUPPORTED        0x8000000000000003ULL
#define EFI_NOT_FOUND          0x800000000000000EULL
#define EFI_ERROR(s)           (((INTN)(s)) < 0)

typedef struct { UINT32 Data1; UINT16 Data2; UINT16 Data3; UINT8 Data4[8]; } EFI_GUID;

/* well-known GUIDs we use */
#define EFI_LOADED_IMAGE_PROTOCOL_GUID \
  { 0x5B1B31A1,0x9562,0x11d2,{0x8E,0x3F,0x00,0xA0,0xC9,0x69,0x72,0x3B}}
#define EFI_SIMPLE_FILE_SYSTEM_PROTOCOL_GUID \
  { 0x0964e5b22,0x6459,0x11d2,{0x8e,0x39,0x00,0xa0,0xc9,0x69,0x72,0x3b}}
#define EFI_FILE_INFO_ID \
  { 0x09576e92,0x6d3f,0x11d2,{0x8e,0x39,0x00,0xa0,0xc9,0x69,0x72,0x3b}}

/* ---- text output (for the console announcements) ---- */
struct _EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL;
typedef EFI_STATUS (EFIAPI *EFI_TEXT_STRING)(
    struct _EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *This, CHAR16 *String);
typedef struct _EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL {
    VOID *Reset;
    EFI_TEXT_STRING OutputString;
    /* rest unused */
} EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL;

/* ---- file protocol ---- */
typedef struct _EFI_FILE_PROTOCOL EFI_FILE_PROTOCOL;
typedef EFI_STATUS (EFIAPI *EFI_FILE_OPEN)(
    EFI_FILE_PROTOCOL *This, EFI_FILE_PROTOCOL **NewHandle,
    CHAR16 *FileName, UINT64 OpenMode, UINT64 Attributes);
typedef EFI_STATUS (EFIAPI *EFI_FILE_CLOSE)(EFI_FILE_PROTOCOL *This);
typedef EFI_STATUS (EFIAPI *EFI_FILE_DELETE)(EFI_FILE_PROTOCOL *This);
typedef EFI_STATUS (EFIAPI *EFI_FILE_READ)(
    EFI_FILE_PROTOCOL *This, UINTN *BufferSize, VOID *Buffer);
typedef EFI_STATUS (EFIAPI *EFI_FILE_WRITE)(
    EFI_FILE_PROTOCOL *This, UINTN *BufferSize, VOID *Buffer);
typedef EFI_STATUS (EFIAPI *EFI_FILE_GET_INFO)(
    EFI_FILE_PROTOCOL *This, EFI_GUID *InformationType,
    UINTN *BufferSize, VOID *Buffer);
struct _EFI_FILE_PROTOCOL {
    UINT64 Revision;
    EFI_FILE_OPEN Open;
    EFI_FILE_CLOSE Close;
    EFI_FILE_DELETE Delete;
    EFI_FILE_READ Read;
    EFI_FILE_WRITE Write;
    VOID *GetPosition;
    VOID *SetPosition;
    EFI_FILE_GET_INFO GetInfo;
    VOID *SetInfo;
    VOID *Flush;
};
#define EFI_FILE_MODE_READ   0x0000000000000001ULL
#define EFI_FILE_MODE_WRITE  0x0000000000000002ULL

/* EFI_FILE_INFO -- we only need FileSize (offset after the two UINT64s +
 * the create/access/modify times + attribute; but the spec layout is fixed and
 * FileSize is the 2nd UINT64). We read it via GetInfo. */
typedef struct {
    UINT64 Size;
    UINT64 FileSize;
    UINT64 PhysicalSize;
    UINT8  CreateTime[16];
    UINT8  LastAccessTime[16];
    UINT8  ModificationTime[16];
    UINT64 Attribute;
    CHAR16 FileName[1];
} EFI_FILE_INFO;

typedef struct _EFI_SIMPLE_FILE_SYSTEM_PROTOCOL {
    UINT64 Revision;
    EFI_STATUS (EFIAPI *OpenVolume)(
        struct _EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *This, EFI_FILE_PROTOCOL **Root);
} EFI_SIMPLE_FILE_SYSTEM_PROTOCOL;

/* ---- loaded image ---- */
typedef struct {
    UINT32 Revision;
    EFI_HANDLE ParentHandle;
    VOID *SystemTable;
    EFI_HANDLE DeviceHandle;      /* the volume we booted from -- the ESP */
    VOID *FilePath;
    VOID *Reserved;
    UINT32 LoadOptionsSize;
    VOID *LoadOptions;
    VOID *ImageBase;
    UINT64 ImageSize;
    UINT32 ImageCodeType;
    UINT32 ImageDataType;
    VOID *Unload;
} EFI_LOADED_IMAGE_PROTOCOL;

/* ---- boot services (only the calls we use) ---- */
typedef struct {
    UINT8 Hdr[24];
    /* task priority (2) */
    VOID *RaiseTPL; VOID *RestoreTPL;
    /* memory (4) */
    VOID *AllocatePages; VOID *FreePages; VOID *GetMemoryMap;
    EFI_STATUS (EFIAPI *AllocatePool)(UINT32 PoolType, UINTN Size, VOID **Buffer);
    EFI_STATUS (EFIAPI *FreePool)(VOID *Buffer);
    /* event/timer (6) */
    VOID *CreateEvent; VOID *SetTimer; VOID *WaitForEvent; VOID *SignalEvent;
    VOID *CloseEvent; VOID *CheckEvent;
    /* protocol handlers (9, old-style) */
    VOID *InstallProtocolInterface; VOID *ReinstallProtocolInterface;
    VOID *UninstallProtocolInterface;
    EFI_STATUS (EFIAPI *HandleProtocol)(EFI_HANDLE Handle, EFI_GUID *Protocol, VOID **Interface);
    VOID *Reserved;
    VOID *RegisterProtocolNotify; VOID *LocateHandle; VOID *LocateDevicePath;
    VOID *InstallConfigurationTable;
    /* image services */
    EFI_STATUS (EFIAPI *LoadImage)(
        UINT8 BootPolicy, EFI_HANDLE ParentImageHandle, VOID *DevicePath,
        VOID *SourceBuffer, UINTN SourceSize, EFI_HANDLE *ImageHandle);
    EFI_STATUS (EFIAPI *StartImage)(
        EFI_HANDLE ImageHandle, UINTN *ExitDataSize, CHAR16 **ExitData);
    /* ... rest unused */
} EFI_BOOT_SERVICES;

#define EFI_LOADER_DATA 2

typedef struct {
    UINT8 Hdr[24];
    CHAR16 *FirmwareVendor;
    UINT32 FirmwareRevision;
    EFI_HANDLE ConsoleInHandle; VOID *ConIn;
    EFI_HANDLE ConsoleOutHandle;
    EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *ConOut;
    EFI_HANDLE StandardErrorHandle; VOID *StdErr;
    VOID *RuntimeServices;
    EFI_BOOT_SERVICES *BootServices;
    UINTN NumberOfTableEntries;
    VOID *ConfigurationTable;
} EFI_SYSTEM_TABLE;

#endif
