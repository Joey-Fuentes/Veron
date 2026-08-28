#!/usr/bin/env python3
# tools/ext4-extract.py -- unpack an ext4 image into a directory with nothing
# but python's standard library.
#
#     python3 tools/ext4-extract.py IMAGE DIR
#
# WHY NOT debugfs: a statically linked glibc debugfs still dlopen()s the
# host's libc for NSS lookups, and aborts when that libc is not the one it
# was built with ("rtld_static_init: guard_sym != NULL", the runner,
# 2026-08-27). Reading a filesystem is a pure function of its bytes; this
# does it the same way on every host, with the interpreter every host has.
#
# WHAT IT READS: the images this project makes -- mke2fs with
#   -O ^has_journal,^resize_inode,^dir_index,^metadata_csum, -b 4096
# on top of mke2fs's ext4 defaults (extents, 64bit, flex_bg, huge_file,
# extra_isize, dir_nlink, filetype). So: extent trees of any depth, linear
# directories, fast and slow symlinks, hardlinks (by inode), 32- or 64-bit
# group descriptors, inline_data if present. Modes and mtimes are restored;
# ownership is not (an unprivileged process cannot, and the box that
# consumes the tree maps its user to uid 0 anyway). Device nodes and
# sockets are skipped and counted.
import os, struct, sys, stat

class Ext4:
    def __init__(self, path):
        self.f = open(path, 'rb')
        sb = self._read(1024, 1024)
        if struct.unpack_from('<H', sb, 0x38)[0] != 0xEF53:
            sys.exit('ext4-extract: not an ext2/3/4 image (bad magic)')
        (self.s_inodes_count, self.s_blocks_count_lo) = struct.unpack_from('<II', sb, 0)
        self.s_first_data_block = struct.unpack_from('<I', sb, 0x14)[0]
        self.block_size = 1024 << struct.unpack_from('<I', sb, 0x18)[0]
        self.s_blocks_per_group = struct.unpack_from('<I', sb, 0x20)[0]
        self.s_inodes_per_group = struct.unpack_from('<I', sb, 0x28)[0]
        self.s_inode_size = struct.unpack_from('<H', sb, 0x58)[0] or 128
        feat_incompat = struct.unpack_from('<I', sb, 0x60)[0]
        self.incompat = feat_incompat
        self.is64 = bool(feat_incompat & 0x80)
        self.s_desc_size = struct.unpack_from('<H', sb, 0xFE)[0] if self.is64 else 32
        if self.s_desc_size == 0:
            self.s_desc_size = 64 if self.is64 else 32
        # group descriptor table follows the superblock's block
        gdt_block = self.s_first_data_block + 1
        ngroups = (self.s_blocks_count_lo + self.s_blocks_per_group - 1) // self.s_blocks_per_group
        gdt = self._read(gdt_block * self.block_size, ngroups * self.s_desc_size)
        self.inode_tables = []
        for g in range(ngroups):
            d = gdt[g * self.s_desc_size:(g + 1) * self.s_desc_size]
            lo = struct.unpack_from('<I', d, 0x08)[0]
            hi = struct.unpack_from('<I', d, 0x28)[0] if self.s_desc_size >= 64 else 0
            self.inode_tables.append((hi << 32) | lo)
        self.stats = {'files': 0, 'dirs': 0, 'symlinks': 0, 'hardlinks': 0, 'skipped': 0}

    def _read(self, off, n):
        self.f.seek(off); b = self.f.read(n)
        if len(b) != n: raise IOError(f'short read at {off}')
        return b

    def inode(self, ino):
        g, idx = divmod(ino - 1, self.s_inodes_per_group)
        off = self.inode_tables[g] * self.block_size + idx * self.s_inode_size
        raw = self._read(off, self.s_inode_size)
        i = {}
        i['mode'] = struct.unpack_from('<H', raw, 0)[0]
        size_lo = struct.unpack_from('<I', raw, 4)[0]
        size_hi = struct.unpack_from('<I', raw, 0x6C)[0]
        i['size'] = (size_hi << 32) | size_lo
        i['mtime'] = struct.unpack_from('<I', raw, 0x10)[0]
        i['links'] = struct.unpack_from('<H', raw, 0x1A)[0]
        i['flags'] = struct.unpack_from('<I', raw, 0x20)[0]
        i['block'] = raw[0x28:0x28 + 60]
        i['raw'] = raw
        return i

    # ---- data: extents (depth-first, in logical order) or inline ----
    def extents(self, node, out):
        magic, entries, _max, depth = struct.unpack_from('<HHHH', node, 0)
        if magic != 0xF30A: raise IOError('bad extent header')
        for k in range(entries):
            e = node[12 + 12 * k:24 + 12 * k]
            if depth == 0:
                lblk, length, start_hi, start_lo = struct.unpack_from('<IHHI', e, 0)
                if length > 32768: length -= 32768   # uninitialized extent: still data
                out.append((lblk, length, (start_hi << 32) | start_lo))
            else:
                lblk, leaf_lo, leaf_hi = struct.unpack_from('<IIH', e, 0)
                leaf = (leaf_hi << 32) | leaf_lo
                self.extents(self._read(leaf * self.block_size, self.block_size), out)
        return out

    def data(self, i):
        size = i['size']
        if i['flags'] & 0x10000000:   # EXT4_INLINE_DATA_FL
            return i['block'][:min(size, 60)]
        if not i['flags'] & 0x80000:  # EXT4_EXTENTS_FL absent: block map (not made by this project)
            raise IOError('block-mapped inode: not an image this project makes')
        ext = self.extents(i['block'], [])
        buf = bytearray(size)
        for lblk, length, pblk in ext:
            off = lblk * self.block_size
            n = min(length * self.block_size, size - off)
            if n <= 0: continue
            if pblk == 0: continue   # hole
            buf[off:off + n] = self._read(pblk * self.block_size, n)
        return bytes(buf)

    def readdir(self, i):
        d = self.data(i); out = []
        pos = 0
        while pos + 8 <= len(d):
            ino, rec_len, name_len, ftype = struct.unpack_from('<IHBB', d, pos)
            if rec_len == 0: break
            if ino != 0:
                name = d[pos + 8:pos + 8 + name_len]
                if name not in (b'.', b'..'):
                    out.append((name.decode('utf-8', 'surrogateescape'), ino))
            pos += rec_len
        return sorted(out)

    def symlink_target(self, i):
        if i['size'] < 60 and not (i['flags'] & 0x80000):
            return i['block'][:i['size']]
        return self.data(i)

    def extract(self, ino, dest, seen):
        i = self.inode(ino)
        m = i['mode']
        os.makedirs(dest, exist_ok=True)
        for name, cino in self.readdir(i):
            c = self.inode(cino); cm = c['mode']; p = os.path.join(dest, name)
            if stat.S_ISDIR(cm):
                os.makedirs(p, exist_ok=True)
                self.extract(cino, p, seen)
                os.chmod(p, cm & 0o7777)
                os.utime(p, (c['mtime'], c['mtime']))
                self.stats['dirs'] += 1
            elif stat.S_ISREG(cm):
                if cino in seen:
                    os.link(seen[cino], p); self.stats['hardlinks'] += 1
                else:
                    with open(p, 'wb') as fh: fh.write(self.data(c))
                    os.chmod(p, cm & 0o7777)
                    os.utime(p, (c['mtime'], c['mtime']))
                    seen[cino] = p; self.stats['files'] += 1
            elif stat.S_ISLNK(cm):
                os.symlink(self.symlink_target(c).decode('utf-8', 'surrogateescape'), p)
                self.stats['symlinks'] += 1
            else:
                self.stats['skipped'] += 1
        return

def main():
    if len(sys.argv) != 3:
        sys.exit('usage: ext4-extract.py IMAGE DIR')
    img, dest = sys.argv[1], sys.argv[2]
    fs = Ext4(img)
    fs.extract(2, dest, {})
    s = fs.stats
    print(f"ext4-extract: {s['files']} files, {s['dirs']} dirs, {s['symlinks']} symlinks, "
          f"{s['hardlinks']} hardlinks, {s['skipped']} special skipped  (block {fs.block_size}, "
          f"inode {fs.s_inode_size}, {'64bit' if fs.is64 else '32bit'} descriptors)")

if __name__ == '__main__':
    main()
