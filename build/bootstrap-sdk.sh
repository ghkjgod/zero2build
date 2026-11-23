#!/usr/bin/env bash
# 拉取固定版本的上游 orangepi-build SDK，并叠加本仓库的改动。
#
# 用法：
#   ./build/bootstrap-sdk.sh                    # 拉取并打补丁到 ./sdk
#   SDK_DIR=/opt/zero2-sdk ./build/bootstrap-sdk.sh
#
# 需要：git、patch（或 git apply）、足够磁盘空间（源码 + 工具链约 3 GB，
# 完整构建建议预留 25 GB）。

set -euo pipefail

SDK_UPSTREAM="${SDK_UPSTREAM:-https://github.com/orangepi-xunlong/orangepi-build.git}"
# 本仓库的改动是针对这个提交验证的；换版本时补丁可能需要重新对齐。
SDK_COMMIT="${SDK_COMMIT:-7f24222b928eab94780f2af03289ce527e07241e}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdk_dir="${SDK_DIR:-$repo_root/sdk}"
overlay="$repo_root/sdk-overlay"

log() { printf '\n==> %s\n' "$*"; }

if [[ -d $sdk_dir/.git ]]; then
    log "复用已有 SDK：$sdk_dir"
else
    log "克隆上游 orangepi-build 到 $sdk_dir"
    git clone "$SDK_UPSTREAM" "$sdk_dir"
fi

log "切换到验证过的提交 $SDK_COMMIT"
# 只移动 HEAD，不删除已下载的内核/U-Boot 源码目录和 output/。
git -C "$sdk_dir" checkout --detach "$SDK_COMMIT"

log "应用本仓库的 SDK 补丁"
shopt -s nullglob
patches=("$overlay"/patches/*.patch)
(( ${#patches[@]} )) || { echo "找不到补丁：$overlay/patches" >&2; exit 1; }
for patch in "${patches[@]}"; do
    if git -C "$sdk_dir" apply --check --reverse "$patch" 2>/dev/null; then
        echo "已应用，跳过：$(basename "$patch")"
        continue
    fi
    git -C "$sdk_dir" apply --check "$patch" || {
        echo "补丁与当前 SDK 不匹配：$(basename "$patch")" >&2
        echo "如已升级上游提交，请先检查 diff 再更新补丁。" >&2
        exit 1
    }
    git -C "$sdk_dir" apply "$patch"
    echo "已应用：$(basename "$patch")"
done

log "安装 userpatches（构建配置、镜像定制脚本、额外软件包）"
# userpatches/ 在上游 .gitignore 中，这里整目录同步本仓库的版本，
# 同时保留上游自带的示例配置（cron、vagrant 等）不受影响。
mkdir -p "$sdk_dir/userpatches"
cp -a "$overlay/userpatches/." "$sdk_dir/userpatches/"

log "完成"
cat <<EOF

SDK 目录：$sdk_dir
上游提交：$(git -C "$sdk_dir" rev-parse --short HEAD)
构建入口：cd "$sdk_dir" && ./build.sh zero2-xfce

首次构建前请先看 docs/BUILD.md。
EOF
