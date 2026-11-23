#!/bin/bash
# Zero2 首次开机后的一次性修复与自检。
#
# 背景：本镜像由 orangepi-build 的 tar 管道生成，过程中 dpkg 的文件能力
# （capabilities）没有写入 ext4 的 security xattr，导致 snap-confine 缺
# cap_dac_override，Chromium 等 snap 起不来；另外内存日志（ramlog）目录
# 在 xrdp 启动时还没准备好 /var/log/xrdp.log，使 xrdp 直接失败。
#
# 用法（在板子上，以普通用户执行）：
#   sudo ./firstboot-fix.sh
#
# 全部操作可重复执行；已修好的项目会自动跳过。

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "请用 sudo 运行" >&2; exit 1; }

step() { printf '\n==> %s\n' "$*"; }

step "1/4 恢复 snap-confine 的文件能力"
if [[ -s /usr/lib/snapd/snap-confine.caps ]]; then
    setcap - /usr/lib/snapd/snap-confine < /usr/lib/snapd/snap-confine.caps
    if getcap /usr/lib/snapd/snap-confine | grep -q cap_dac_override; then
        echo "OK: $(getcap /usr/lib/snapd/snap-confine)"
    else
        echo "失败：文件能力没有生效，请检查根文件系统是否挂载了 nosuid 或缺少 xattr" >&2
        exit 1
    fi
else
    echo "跳过：不存在 /usr/lib/snapd/snap-confine.caps"
fi

step "2/4 校验 dpkg 记录的系统二进制"
# 生成镜像时 systemctl 曾被写坏（表现为 systemctl 任何调用都 Assertion 崩溃）。
# 这里做只读校验，只报告不自动改动。
if (cd / && grep -E '  (usr/)?bin/systemctl$' /var/lib/dpkg/info/systemd.md5sums | md5sum -c -); then
    :
else
    echo "警告：/usr/bin/systemctl 与软件包记录不一致。" >&2
    echo "      修复方法：apt-get install --reinstall systemd" >&2
fi

step "3/4 修复 xrdp 的内存日志目录"
install -d -m 0755 /etc/tmpfiles.d /etc/systemd/system/xrdp.service.d
cat > /etc/tmpfiles.d/zero2-xrdp-log.conf <<'EOF'
f /var/log/xrdp.log 0640 xrdp adm -
EOF
cat > /etc/systemd/system/xrdp.service.d/zero2-ramlog.conf <<'EOF'
[Unit]
After=orangepi-ramlog.service
[Service]
ExecStartPre=+/usr/bin/systemd-tmpfiles --create /etc/tmpfiles.d/zero2-xrdp-log.conf
EOF
systemctl daemon-reload
echo "已写入 /etc/tmpfiles.d/zero2-xrdp-log.conf 与 xrdp drop-in"

step "4/4 启用客户端网络模型，停用未配置的热点服务"
# 出厂镜像同时启用了 hostapd/dnsmasq（AP 模式）与 NetworkManager（客户端模式），
# 二者抢同一个无线接口和 53 端口。桌面镜像默认走客户端模式。
if systemctl is-active --quiet NetworkManager; then
    systemctl disable --now hostapd dnsmasq 2>/dev/null || true
    systemctl disable zramswap 2>/dev/null || true   # 与 orangepi-zram-config 重复
    systemctl reset-failed 2>/dev/null || true
    echo "OK: 保留 NetworkManager 与 orangepi-zram-config"
else
    echo "跳过：NetworkManager 未运行，保持当前网络配置"
fi

printf '\n完成。建议重启一次，然后执行：\n'
printf '  sudo opi-display-check        # HDMI / GPU / V4L2 状态\n'
printf '  systemctl --failed            # 应为 0 loaded units listed\n'
printf '  glxinfo -B                    # 应为 Mali-G31 (Panfrost)\n'
