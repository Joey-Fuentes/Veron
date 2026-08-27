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
import sys, os, io, tarfile, hashlib, subprocess, shutil

def find_zstd():
    for cand, prov in ((os.environ.get('VERON_TOOLS', '') and os.path.join(os.environ['VERON_TOOLS'], 'zstd'), 'VERON_TOOLS'),
                       ('veron-tools/zstd', 'veron-tools bundle'), (shutil.which('zstd') or '', 'system')):
        if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand, prov
    sys.exit('pack.py: no zstd found (VERON_TOOLS, veron-tools/, or PATH)')

def add_tree(tf, root, arcroot):
    entries = []
    for dp, dns, fns in os.walk(root, followlinks=False):
        rel = os.path.relpath(dp, root)
        for n in dns + fns:
            entries.append(os.path.normpath(os.path.join(rel, n)))
    for rel in sorted(entries, key=lambda s: s.encode()):
        full = os.path.join(root, rel)
        ti = tf.gettarinfo(full, arcname=os.path.join(arcroot, rel) if arcroot else rel)
        ti.uid = ti.gid = 0; ti.uname = ti.gname = ''; ti.mtime = 0
        if ti.isfile():
            with open(full, 'rb') as f: tf.addfile(ti, f)
        else:
            tf.addfile(ti)

def main(argv):
    level, record, files = 19, None, False
    args = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '-l': level = int(argv[i + 1]); i += 2; continue
        if a == '--record': record = argv[i + 1]; i += 2; continue
        if a == '-f': files = True; i += 1; continue
        args.append(a); i += 1
    out, inputs = args[0], args[1:]
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w', format=tarfile.GNU_FORMAT) as tf:
        if files:
            for p in sorted(inputs, key=lambda s: os.path.basename(s).encode()):
                ti = tf.gettarinfo(p, arcname=os.path.basename(p))
                ti.uid = ti.gid = 0; ti.uname = ti.gname = ''; ti.mtime = 0
                with open(p, 'rb') as f: tf.addfile(ti, f)
        else:
            for d in inputs:
                add_tree(tf, d, '')
    tar_bytes = buf.getvalue()
    zstd, prov = find_zstd()
    r = subprocess.run([zstd, f'-{level}', '-T1', '-q', '--no-progress', '-o', out, '-f'], input=tar_bytes, check=True)
    zsha = hashlib.sha256(open(zstd, 'rb').read()).hexdigest()
    tsha = hashlib.sha256(tar_bytes).hexdigest()
    osha = hashlib.sha256(open(out, 'rb').read()).hexdigest()
    line = f'packed-by  tar {tsha}  zstd-binary {zsha} ({prov}, level {level}, -T1)  archive {osha}  {os.path.basename(out)}'
    print(line)
    if record:
        with open(record, 'a') as f: f.write(line + '\n')

if __name__ == '__main__':
    main(sys.argv[1:])
