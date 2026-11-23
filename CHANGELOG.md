# 变更记录

## 2026-11-23 — 首次可用版本

### 已验证

- Orange Pi Zero2（H616）从板载卡槽冷启动成功，内核 `6.1.31-sun50iw9`
- XFCE + LightDM 桌面运行，`systemctl --failed` 为 0
- Panfrost 接管 Mali-G31，`glxinfo -B` 显示 `direct rendering: Yes`
- Chromium 158.0.8127.36 以普通用户无头渲染成功
- 有线网络 DHCP 正常，SSH 可登录；`wlan0`、`hci0` 已枚举
- Cedrus 枚举 H.264 / HEVC / VP8 / MPEG-2 输出格式

### 未验证

- HDMI 2K/4K 实际输出（验收时未接显示器）
- Chromium 播放视频时是否真正走硬件解码
- 蓝牙配对与传输
- xrdp 图形会话登录（仅验证 3389 端口可达）

### 相对首版镜像的修复

只读挂载成品镜像逐项核对后，把三个出厂问题修在构建阶段而非留给用户：

1. **文件能力全部丢失**：镜像内 `getcap -r` 无任何输出。rootfs 缓存的
   `tar --xattrs` 管道没有保住 `security.capability`，导致 `snap-confine`
   缺 `cap_dac_override`、Chromium 无法启动。现在 `customize-image.sh`
   在 chroot 内按 `/usr/lib/snapd/*.caps` 重新应用，随后 SDK 用
   `rsync -aHWX` 把 xattr 带进 ext4 镜像。
2. **xrdp 起不来**：ramlog 把 `/var/log` 换成 tmpfs 后日志文件不存在，
   xrdp 无权创建。已在镜像内预置 tmpfiles 规则和 systemd drop-in。
3. **网络服务冲突**：hostapd/dnsmasq（未配置的 AP 模式）与 NetworkManager
   抢接口，`zramswap` 与 `orangepi-zram-config` 重复。构建时移除前者的
   启动链接，保留 NetworkManager 与原厂 zram。

### 纠正一处误判

板上曾观察到 `systemctl` 崩溃（`Assertion 'argc >= 1 && argc <= 2' failed`）。
只读挂载镜像并用 chroot 实际执行后确认：镜像内 `systemctl` 的 MD5 与 dpkg
记录一致（`397aa2e8…`），且能正常输出版本。损坏发生在写卡/首次开机之后，
与构建无关——那块 8 GB 卡写入仅 4.84 MB/s，且当时关闭了写后校验。

### 仓库

- 不收录上游 SDK、内核源码与镜像文件，由 `build/bootstrap-sdk.sh` 按固定提交拉取
- 两处上游补丁可用 `git apply --check --reverse` 干净校验
