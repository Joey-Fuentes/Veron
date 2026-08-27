#!/usr/bin/env python3
# tools/diag/modules-diff.py -- compare two modules tarballs member by member:
# which files differ in content, which in metadata (mode, uid, gid, mtime,
# size), which exist in only one. python3 only.
#
#     python3 tools/diag/modules-diff.py A.tar.zst B.tar.zst
#     python3 tools/diag/modules-diff.py box4g/build/staging B.tar.zst   # a staging tree vs a tarball
import sys, tarfile, hashlib
def unzstd(path):
    data = open(path, 'rb').read()
    if not path.endswith('.zst'):
        return data
    try:
        from compression import zstd            # python 3.14+
        return zstd.decompress(data)
    except ImportError:
        import subprocess, shutil               # any python, a zstd binary (pkg install zstd)
        if not shutil.which('zstd'):
            sys.exit('need python 3.14 (compression.zstd) or a zstd binary on PATH')
        return subprocess.run(['zstd', '-dc', path], check=True, capture_output=True).stdout

def load(path):
    """A tarball (.tar / .tar.zst) or a DIRECTORY (a staging tree): members
    keyed by './'-relative path, so a laptop's build/staging can be compared
    with a runner's published tarball directly."""
    import io, os
    members = {}
    if os.path.isdir(path):
        for dp, dns, fns in os.walk(path):
            for n in dns + fns:
                full = os.path.join(dp, n); rel = './' + os.path.relpath(full, path)
                st = os.lstat(full)
                if os.path.islink(full): h, ty = None, b'2'
                elif os.path.isdir(full): h, ty = None, b'5'
                else: h, ty = hashlib.sha256(open(full, 'rb').read()).hexdigest(), b'0'
                members[rel] = (h, st.st_mode & 0o777, 0, 0, 0, st.st_size if ty == b'0' else 0, ty)
        members['.'] = (None, 0o755, 0, 0, 0, 0, b'5')
        return members
    raw = unzstd(path)
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:') as tf:
        for m in tf:
            h = hashlib.sha256(tf.extractfile(m).read()).hexdigest() if m.isfile() else None
            members[m.name] = (h, m.mode, m.uid, m.gid, m.mtime, m.size, m.type)
    return members
a, b = load(sys.argv[1]), load(sys.argv[2])
only_a = sorted(set(a) - set(b)); only_b = sorted(set(b) - set(a))
content = [n for n in sorted(set(a) & set(b)) if a[n][0] != b[n][0]]
meta = [n for n in sorted(set(a) & set(b)) if a[n][0] == b[n][0] and a[n][1:] != b[n][1:]]
print(f'members: A {len(a)}, B {len(b)}; only in A {len(only_a)}, only in B {len(only_b)}')
print(f'content differs: {len(content)}; metadata differs (same content): {len(meta)}')
for n in content[:30]: print('  content:', n)
for n in meta[:30]: print('  meta:', n, a[n][1:], '->', b[n][1:])
for n in only_a[:10]: print('  only A:', n)
for n in only_b[:10]: print('  only B:', n)
# order of members is part of the bytes too
if list(a) != list(b) and set(a) == set(b): print('member ORDER differs (same set)')
