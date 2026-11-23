#!/usr/bin/env bash
# 在本机（Linux / WSL2 的 ext4 目录）构建 Zero2 镜像。
#
# 前置：先执行 build/bootstrap-sdk.sh 准备好 ./sdk
# 要求：x86_64 Linux、ext4 文件系统、root 权限、约 25 GB 空闲空间。
#       不要在 NTFS/DrvFs 上构建：内核编译和 tar 解包会慢到不可用。
#
# 用法：
#   sudo ./build/build-image.sh
#   SKIP_CHROMIUM_SEED=1 sudo ./build/build-image.sh   # 跳过 Chromium 预置

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdk_dir="${SDK_DIR:-$repo_root/sdk}"
config="${CONFIG:-zero2-xfce}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\n[错误] %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "需要 root：内核 deb 安装和 loop 设备操作都要求 root。"
[[ -x $sdk_dir/build.sh ]] || die "找不到 $sdk_dir/build.sh，请先运行 build/bootstrap-sdk.sh。"

fs=$(findmnt -no FSTYPE -T "$sdk_dir")
[[ $fs == ext4 || $fs == btrfs || $fs == xfs ]] || die "$sdk_dir 位于 $fs，请放到 ext4 上再构建。"

cd "$sdk_dir"
export TMPDIR="$sdk_dir/tmp"
mkdir -p "$TMPDIR" output

# 1. Chromium：Jammy 的 chromium-browser deb 只是启动器，
#    真正的 ARM64 浏览器必须以 snap seed 的形式预先写进镜像。
if [[ ${SKIP_CHROMIUM_SEED:-0} != 1 ]]; then
    log "准备 Chromium ARM64 snap seed（约 1 GB 下载）"
    bash "$repo_root/build/linux/prepare-chromium-seed.sh"
else
    log "已跳过 Chromium seed"
fi

# 2. 构建内核 deb（若已存在则跳过，避免重复编译数小时）
if [[ ! -s output/debs/linux-image-next-sun50iw9_3.1.0_arm64.deb ]]; then
    log "构建内核与 U-Boot"
    bash build.sh "$config" CLEAN_LEVEL= KERNEL_KEEP_CONFIG=yes BUILD_KSRC=no BUILD_OPT=kernel
else
    log "内核 deb 已存在，跳过编译"
fi

# 3. 组装根文件系统并生成 .img
log "组装镜像"
bash build.sh "$config" CLEAN_LEVEL= KERNEL_KEEP_CONFIG=yes BUILD_KSRC=no \
    BUILD_OPT=image SKIP_EXTERNAL_TOOLCHAINS=yes FORCE_USE_RAMDISK=no

# 4. 汇总产物
shopt -s nullglob
images=(output/images/*.img)
(( ${#images[@]} )) || die "构建结束但没有生成 .img"
for img in "${images[@]}"; do
    name=${img##*/}
    hash=$(sha256sum "$img" | cut -d' ' -f1)
    printf '%s  %s\n' "$hash" "$name" | tee "output/images/$name.sha256"
done

log "完成：$sdk_dir/output/images/"
