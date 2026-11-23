#!/bin/bash
set -e

# Keep XFCE usable on both the 512 MB and 1 GB board variants.
if command -v systemctl >/dev/null 2>&1 && [ -d /etc/default ]; then
    cat >/etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
EOF
fi

# One-shot diagnostics that can be run over the COM5 serial console after boot.
cat >/usr/local/sbin/opi-display-check <<'EOF'
#!/bin/sh
set -u

echo '=== kernel ==='
uname -a
echo '=== DRM connectors ==='
for d in /sys/class/drm/card*-HDMI-A-*; do
    [ -e "$d" ] || continue
    echo "[$d] status=$(cat "$d/status" 2>/dev/null || true)"
    echo 'modes:'
    cat "$d/modes" 2>/dev/null || true
    if [ -s "$d/edid" ] && command -v edid-decode >/dev/null 2>&1; then
        echo 'edid:'
        edid-decode "$d/edid" 2>/dev/null | sed -n '1,35p' || true
    else
        echo 'edid: unavailable'
    fi
done
echo '=== GPU/VPU modules ==='
lsmod 2>/dev/null | grep -E 'panfrost|sunxi_cedrus|cedrus|gpu_sched' || true
echo '=== OpenGL ==='
if command -v glxinfo >/dev/null 2>&1; then
    glxinfo -B 2>/dev/null | grep -E 'direct rendering|OpenGL renderer|OpenGL version' || true
fi
echo '=== V4L2 ==='
if command -v v4l2-ctl >/dev/null 2>&1; then
    v4l2-ctl --list-devices 2>/dev/null || true
fi
EOF
chmod 0755 /usr/local/sbin/opi-display-check

# The Orange Pi 6.1 H616 device tree contains the Mali node but ships it
# disabled. Enable it from the U-Boot fixup script so the generic Panfrost
# driver can bind without replacing the board DTS.
if command -v mkimage >/dev/null 2>&1 && [ -d /boot ]; then
    cat >/boot/fixup.cmd <<'EOF'
fdt set /soc/gpu@1800000 status okay
EOF
    mkimage -C none -A arm -T script -d /boot/fixup.cmd /boot/fixup.scr >/dev/null 2>&1 || true
fi

if [ -f /etc/modules ] && ! grep -qx 'panfrost' /etc/modules; then
    echo panfrost >>/etc/modules
fi

# snap 应用依赖 snap-confine 上的文件能力（cap_dac_override 等）。这些能力存在
# ext4 的 security.capability xattr 里，而 dpkg 的 postinst 在 qemu-user 下执行
# setcap 时可能不落盘，结果是镜像里的 snap-confine 文件属性完整、能力却为空，
# 首次开机后 chromium 报 "snap-confine is packaged without necessary permissions"。
# 这里按软件包自带的 .caps 清单重新应用一次。
if [ -d /usr/lib/snapd ]; then
    for capsfile in /usr/lib/snapd/*.caps; do
        [ -s "$capsfile" ] || continue
        target=${capsfile%.caps}
        [ -f "$target" ] || continue
        if setcap - "$target" < "$capsfile" 2>/dev/null; then
            echo "文件能力已应用：$target"
        else
            echo "警告：无法为 $target 应用文件能力，首次开机需运行 firstboot-fix.sh" >&2
        fi
        if command -v getcap >/dev/null 2>&1; then
            getcap "$target" || echo "警告：$target 仍无文件能力" >&2
        fi
    done
fi

# xrdp 在 orangepi-ramlog 把 /var/log 切成 tmpfs 之前启动，此时日志文件不存在，
# 而 xrdp 以 xrdp 用户运行、无权在 root:syslog 775 的目录里新建文件，于是直接失败。
# 用 tmpfiles 规则 + drop-in 保证 ramlog 之后以正确属主创建日志。
if [ -d /etc/systemd/system ]; then
    install -d -m 0755 /etc/tmpfiles.d /etc/systemd/system/xrdp.service.d
    cat >/etc/tmpfiles.d/zero2-xrdp-log.conf <<'EOF'
f /var/log/xrdp.log 0640 xrdp adm -
EOF
    cat >/etc/systemd/system/xrdp.service.d/zero2-ramlog.conf <<'EOF'
[Unit]
After=orangepi-ramlog.service
[Service]
ExecStartPre=+/usr/bin/systemd-tmpfiles --create /etc/tmpfiles.d/zero2-xrdp-log.conf
EOF
fi

# 出厂镜像同时启用了 hostapd+dnsmasq（AP 模式，但没配 SSID 必然失败）
# 与 NetworkManager（客户端模式），两者抢无线接口和 53 端口。桌面镜像走客户端模式。
if [ -x /usr/bin/systemctl ] || [ -x /bin/systemctl ]; then
    for unit in hostapd dnsmasq zramswap; do
        rm -f "/etc/systemd/system/multi-user.target.wants/$unit.service"
        rm -f "/etc/systemd/system/sysinit.target.wants/$unit.service"
        rm -f "/etc/systemd/system/basic.target.wants/$unit.service"
    done
fi
