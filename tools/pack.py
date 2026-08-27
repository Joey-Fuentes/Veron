#!/usr/bin/env python3
# tools/pack.py -- THE ONE PACKER for every archive this project publishes.
#
#     python3 tools/pack.py [-l LEVEL] [--record FILE] OUT.tar.zst DIR [DIR...]
#     python3 tools/pack.py [-l LEVEL] [--record FILE] OUT.tar.zst -f FILE [FILE...]
#
# WHY: an archive's bytes depend on what wrote it. GNU tar --sort=name and
# busybox tar order members differently and write different headers, and
# two zstd builds compress the same input to different bytes. So published
# archives from a runner and a laptop disagreed while every file inside them
# was identical (modules tarball, 2026-08-27; sysroot never made on the
# image at all). One packer, in python's standard library, and one
# compressor, this project's own zstd, on every host:
#   - members sorted bytewise by name, directories before their contents
#   - GNU format; uid/gid 0, no names; mtime 0; mode kept (executable bits
#     matter), symlinks kept as symlinks
#   - zstd: $VERON_TOOLS/zstd, then ./veron-tools/zstd (the bundle), then the
#     system's; single thread, no checksum-bearing frame extras; the binary
#     used is RECORDED by sha256 so a mismatch has a name
# The record line goes to --record (appended), so a release's SHA256 file
# can sit beside "packed-by zstd <sha256> <provenance>".
import sys, os, tarfile, hashlib, subprocess, shutil

def find_zstd():
    for cand, prov in ((os.environ.get('VERON_TOOLS', '') and os.path.join(os.environ['VERON_TOOLS'], 'zstd'), 'VERON_TOOLS'),
                       ('veron-tools/zstd', 'veron-tools bundle'), (shutil.which('zstd') or '', 'system')):
        if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand, prov
    sys.exit('pack.py: no zstd found (VERON_TOOLS, veron-tools/, or PATH)')

def add_tree(tf, root, arcroot, exclude=()):
    entries = []
    for dp, dns, fns in os.walk(root, followlinks=False):
        rel = os.path.relpath(dp, root)
        for n in dns + fns:
            e = os.path.normpath(os.path.join(rel, n))
            if any(e == x or e.startswith(x + '/') for x in exclude): continue
            entries.append(e)
    for rel in sorted(entries, key=lambda s: s.encode()):
        full = os.path.join(root, rel)
        ti = tf.gettarinfo(full, arcname=os.path.join(arcroot, rel) if arcroot else rel)
        ti.uid = ti.gid = 0; ti.uname = ti.gname = ''; ti.mtime = 0
        if ti.isfile():
            with open(full, 'rb') as f: tf.addfile(ti, f)
        else:
            tf.addfile(ti)

def main(argv):
    level, record, files, tar_only, exclude = 19, None, False, False, []
    args = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '-l': level = int(argv[i + 1]); i += 2; continue
        if a == '--record': record = argv[i + 1]; i += 2; continue
        if a == '-f': files = True; i += 1; continue
        if a == '--tar-only': tar_only = True; i += 1; continue
        if a == '--exclude': exclude.append(argv[i + 1]); i += 2; continue
        args.append(a); i += 1
    out, inputs = args[0], args[1:]
    # STREAMED, NOT BUFFERED: a 4 GB system does not fit a BytesIO on a
    # 7 GiB laptop. The tar goes to a file as it is written, hashed on the
    # way; the compressed form (when asked for) is made from that file.
    class HashingFile:
        def __init__(self, f): self.f, self.h = f, hashlib.sha256()
        def write(self, b): self.h.update(b); return self.f.write(b)
        def tell(self): return self.f.tell()
        def flush(self): self.f.flush()
        def close(self): self.f.close()
    tar_path = out if tar_only else out + '.tar.tmp'
    hf = HashingFile(open(tar_path, 'wb'))
    with tarfile.open(fileobj=hf, mode='w', format=tarfile.GNU_FORMAT) as tf:
        if files:
            for p in sorted(inputs, key=lambda s: os.path.basename(s).encode()):
                ti = tf.gettarinfo(p, arcname=os.path.basename(p))
                ti.uid = ti.gid = 0; ti.uname = ti.gname = ''; ti.mtime = 0
                with open(p, 'rb') as f: tf.addfile(ti, f)
        else:
            for d in inputs:
                add_tree(tf, d, '', exclude)
    hf.close()
    tsha = hf.h.hexdigest()
    if tar_only:
        # the tar alone, uncompressed: the caller compresses it OUTSIDE this
        # process (pack-in-box.sh does, on the host, with whichever zstd it
        # found and records) -- a dynamic zstd cannot run inside a box
        # rooted at a different libc
        print(f'tar {tsha}  {os.path.basename(out)}')
        return
    zstd, prov = find_zstd()
    subprocess.run([zstd, f'-{level}', '-T1', '-q', '--no-progress', '-f', '-o', out, tar_path], check=True)
    os.remove(tar_path)
    zsha = hashlib.sha256(open(zstd, 'rb').read()).hexdigest()
    osha = hashlib.sha256(open(out, 'rb').read()).hexdigest()
    line = f'packed-by  tar {tsha}  zstd-binary {zsha} ({prov}, level {level}, -T1)  archive {osha}  {os.path.basename(out)}'
    print(line)
    if record:
        with open(record, 'a') as f: f.write(line + '\n')

if __name__ == '__main__':
    main(sys.argv[1:])
