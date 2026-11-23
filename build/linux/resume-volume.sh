#!/bin/bash
# Resume the frozen Zero2 SDK build at the same absolute path, on ext4.
#
# 本脚本是**本机专用**的断点续编记录，不要期望它在别的机器上直接可用：
# 它假设 /root/orangepi 这个路径、/export 作为镜像出口、以及已经编译好的
# linux-image-next-sun50iw9 deb。新机器请直接用 build/build-image.sh 从零构建。
set -euo pipefail
cd /root/orangepi
export TMPDIR=$PWD/tmp
test -f "$TMPDIR/migration-complete"
test "$(findmnt -no FSTYPE -T .)" = ext4
tc="$PWD/toolchains/gcc-arm-9.2-2019.12-x86_64-aarch64-none-linux-gnu/bin"
export PATH="$tc:$PATH"
test "$(aarch64-none-linux-gnu-gcc -dumpversion)" = 9.2.1

# Restore Linux line endings and executable bits of SDK text inputs exported
# through Windows Git, without touching kernel build inputs or their mtimes.
python3 - <<'PY'
import os, subprocess
from pathlib import Path
for row in subprocess.check_output(['git','ls-files','--eol','-z']).split(b'\0'):
    if not row: continue
    attrs, name = row.split(b'\t',1)
    p = Path(os.fsdecode(name))
    if b'i/lf' in attrs.split() and (b'w/crlf' in attrs.split() or b'w/mixed' in attrs.split()) and p.is_file() and not p.is_symlink():
        b = p.read_bytes(); p.write_bytes(b.replace(b'\r\n', b'\n'))
for row in subprocess.check_output(['git','ls-files','-s','-z']).split(b'\0'):
    if not row: continue
    info, name = row.split(b'\t',1); mode, blob, _ = info.split(); p = Path(os.fsdecode(name))
    if mode == b'120000' and p.is_file() and not p.is_symlink():
        value = subprocess.check_output(['git','cat-file','blob',blob]);
        if p.read_bytes().rstrip(b'\r\n') == value:
            p.unlink(); p.symlink_to(os.fsdecode(value))
    elif mode == b'100755' and p.is_file() and not p.is_symlink(): p.chmod(p.stat().st_mode | 0o111)
PY
python3 /task-scripts/repair-kernel-case.py kernel/orange-pi-6.1-sun50iw9
# SDK package list files consist only of package names.
sed -i '/^[[:space:]]*#/d' userpatches/cli/_all_distributions/main/packages
common=(zero2-xfce CLEAN_LEVEL= KERNEL_KEEP_CONFIG=yes BUILD_KSRC=no)
# Use the migrated checkout without fetching/resetting it during the resumed make.
if [[ ! -s output/debs/linux-image-next-sun50iw9_3.1.0_arm64.deb ]]; then
    OFFLINE_WORK=yes bash build.sh "${common[@]}" BUILD_OPT=kernel IGNORE_UPDATES=yes
fi
test -s output/debs/linux-image-next-sun50iw9_3.1.0_arm64.deb
# The SDK now reuses the kernel and U-Boot debs. Other image components may need network access.
mkdir -p /var/cache/zero2-build "$PWD/tmp/apt-cache"
ln -sfnT "$PWD/tmp" /var/cache/zero2-build/tmp
export TMPDIR=/var/cache/zero2-build/tmp
font="$TMPDIR/apt-cache/fonts-noto-cjk-extra.deb"
if [[ ! -s $font ]]; then
    rel='pool/main/f/fonts-noto-cjk/fonts-noto-cjk-extra_20220127%2brepack1-1_all.deb'
    for mirror in https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports https://ports.ubuntu.com/ubuntu-ports; do
        if curl -fsSL --connect-timeout 12 --max-time 360 --retry 2 -C - -o "$font.partial" "$mirror/$rel" &&
            [[ $(dpkg-deb -f "$font.partial" Package) == fonts-noto-cjk-extra ]]; then
            mv "$font.partial" "$font"; break
        fi
    done
fi
bash build.sh "${common[@]}" BUILD_OPT=image SKIP_EXTERNAL_TOOLCHAINS=yes IGNORE_UPDATES=yes FORCE_USE_RAMDISK=no
shopt -s nullglob
images=(output/images/*.img output/images/*/*.img)
(( ${#images[@]} > 0 )) || { echo 'Build ended without an image' >&2; exit 1; }
for img in "${images[@]}"; do
    test -s "$img"
    name=${img##*/}
    hash=$(sha256sum "$img" | cut -d' ' -f1)
    cp --sparse=always "$img" "/export/$name.partial"
    echo "$hash  /export/$name.partial" | sha256sum -c -
    mv -T "/export/$name.partial" "/export/$name"
    printf '%s  %s\n' "$hash" "$name" > "/export/$name.sha256"
done
