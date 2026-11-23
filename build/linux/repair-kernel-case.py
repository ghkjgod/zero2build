"""Restore case-distinct kernel inputs collapsed by the Windows checkout."""
import os
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

os.chdir(sys.argv[1])
groups = defaultdict(list)
for row in subprocess.check_output(['git', 'ls-tree', '-rz', 'HEAD']).split(b'\0'):
    if row:
        meta, name = row.split(b'\t', 1)
        mode, kind, oid = meta.split()
        if kind == b'blob':
            groups[os.fsdecode(name).casefold()].append((Path(os.fsdecode(name)), mode, oid))

repaired = 0
for entries in groups.values():
    if len(entries) < 2:
        continue
    blobs = {oid: subprocess.check_output(['git', 'cat-file', 'blob', oid]) for _, _, oid in entries}
    changed = False
    for p, mode, oid in entries:
        expected = blobs[oid]
        exists = os.path.lexists(p)
        if exists:
            actual = os.fsencode(os.readlink(p)) if p.is_symlink() else p.read_bytes()
            if actual == expected:
                continue
            if actual not in blobs.values() and actual.replace(b'\r\n', b'\n') not in blobs.values():
                raise RuntimeError(f'Unexpected local edit at {p}; original left intact')
        if p.is_symlink():
            p.unlink()
        p.parent.mkdir(parents=True, exist_ok=True)
        if mode == b'120000':
            if p.exists(): p.unlink()
            p.symlink_to(os.fsdecode(expected))
        else:
            p.write_bytes(expected)
            p.chmod(int(mode, 8) & 0o777)
        changed = True
        repaired += 1
        print('Restored:', p)
    if changed:
        # Case-colliding C inputs may also have shared a stale .o on NTFS.
        for p, _, _ in entries:
            if not p.is_symlink(): p.touch()
print(f'Case-distinct inputs restored: {repaired}')
