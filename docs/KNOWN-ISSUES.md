# 已知问题

这些现象在本方案产出的镜像上真实出现过，都不是"构建失败"，但会影响首次开机体验。
`build/firstboot-fix.sh` 会处理第 1、3、4 项；第 2 项只做检查并提示。

## 1. snap 应用无法启动：`snap-confine` 缺少文件能力

**现象**

```bash
$ chromium --version
snap-confine is packaged without necessary permissions and cannot continue
required permitted capability cap_dac_override not found in current capabilities
```

**原因**

`snap-confine` 依赖文件 capability（`cap_dac_override` 等）在可执行文件上，
这些能力存放在 ext4 的 `security.capability` xattr 里。而本镜像的根文件系统是
通过 `tar cp --xattrs | tar xp --xattrs` 管道生成的，这条路径丢失了部分文件的
安全属性；`snapd` 包的 `.caps` 清单文件还在，但没有被应用到二进制上。

**已验证的事实**（2026-11-23，只读挂载成品 `.img`）：

```
$ getcap -r /mnt/img          # 镜像内扫描全部文件
（无任何输出）

dpkg 记录:  206f8c6074cabe53b104d03cc90163a3  usr/lib/snapd/snap-confine
镜像实际:   206f8c6074cabe53b104d03cc90163a3  /mnt/img/usr/lib/snapd/snap-confine
```

也就是说：**镜像里没有任何一个文件带文件能力**，不只是 `snap-confine`。二进制内容
完好、`.caps` 清单完好，丢的是 ext4 的 `security.capability` xattr。原因是
rootfs 缓存走 `tar cp --xattrs` 管道，而 `setcap` 在构建的 qemu-user chroot 里
执行时没有落盘。

**已修复**：`sdk-overlay/userpatches/customize-image.sh` 现在会在 chroot 内按
`/usr/lib/snapd/*.caps` 重新应用一次能力。`customize_image` 之后 SDK 用
`rsync -aHWX` 同步到 ext4 镜像，`-X` 会把 xattr 带过去，所以能力能进入最终镜像。

**已生成的旧镜像**仍需手工处理：

```bash
sudo setcap - /usr/lib/snapd/snap-confine < /usr/lib/snapd/snap-confine.caps
getcap /usr/lib/snapd/snap-confine   # 应列出 cap_dac_override,...
```

`firstboot-fix.sh` 会自动做这一步并校验结果，作为兜底。

## 2. `systemctl` 崩溃：`Assertion 'argc >= 1 && argc <= 2' failed`

**现象**

任何 `systemctl` 调用都直接 abort：

```
Assertion 'argc >= 1 && argc <= 2' failed at src/systemctl/systemctl-log-setting.c:75, function log_setting(). Aborting.
```

**重要结论：这不是构建产物的问题。**

以只读方式挂载 `sdk/output/images/*.img` 后核对，并用 chroot 实际执行：

```
dpkg 记录:  397aa2e81a75f817221f332f249e6518  bin/systemctl
镜像实际:   397aa2e81a75f817221f332f249e6518  /mnt/img/usr/bin/systemctl
$ systemctl --version | head -1
systemd 249 (249.11-0ubuntu3.23)
```

三者一致，说明构建出来的镜像里 `systemctl` 完全正常。板上出现的是
`65cc72260aabb3545aab78a18e4db423`，与记录不符——文件是在**写卡或首次开机后**
被改坏的（这块 8 GB 卡写入平均速度只有 4.84 MB/s，且当时按要求关闭了写后校验）。

**处理**

```bash
sudo apt-get install --reinstall systemd
```

若 apt 不可用，也可从同版本 deb 里取出 `bin/systemctl` 覆盖：

```bash
V=$(dpkg-query -W -f='${Version}' systemd)
apt-get download "systemd=$V" && dpkg-deb -x systemd_*.deb /tmp/sd
sudo install -m 0755 /tmp/sd/bin/systemctl /usr/bin/systemctl
```

**预防**：写卡时**不要**关闭校验。慢速卡 + 无校验是最容易出现静默损坏的组合。

## 3. xrdp 启动失败：`Could not start log`

**现象**

```
error opening log file [The log is not properly started]. quitting.
xrdp.service: Control process exited, code=exited, status=1/FAILURE
```

**原因**

Orange Pi 的 `orangepi-ramlog.service` 会在开机早期把 `/var/log` 变成 tmpfs
（`/var/log.hdd` 才是磁盘上的真实目录）。xrdp 在 ramlog 就绪之前就启动，
此时 `/var/log/xrdp.log` 还不存在，而 xrdp 以 `xrdp:xrdp` 身份运行、无权在
`root:syslog 775` 的目录里创建文件，于是直接退出。

**处理**

新增 tmpfiles 规则 + systemd drop-in，确保 ramlog 之后再以正确属主创建日志文件：

```bash
# /etc/tmpfiles.d/zero2-xrdp-log.conf
f /var/log/xrdp.log 0640 xrdp adm -

# /etc/systemd/system/xrdp.service.d/zero2-ramlog.conf
[Unit]
After=orangepi-ramlog.service
[Service]
ExecStartPre=+/usr/bin/systemd-tmpfiles --create /etc/tmpfiles.d/zero2-xrdp-log.conf
```

`firstboot-fix.sh` 会写入这两个文件并 `restart xrdp`。实测重启后 `systemctl --failed`
为 0，Windows 侧可连通 TCP 3389（未测试图形登录）。

## 4. 网络服务冲突：hostapd / dnsmasq 与 NetworkManager 抢接口

**现象**

`hostapd.service` 启动失败，`dnsmasq.service` 因 53 端口被占用退出。

**原因**

出厂镜像同时启用了两种互斥的网络模型：

- `hostapd` + `dnsmasq`：把板子做成 Wi-Fi AP（但没配 SSID/密码，必然失败）
- `NetworkManager`：作为客户端连路由器

桌面镜像应该走后者。

**处理**

```bash
sudo systemctl disable --now hostapd dnsmasq
```

另外 `zramswap.service` 与 Orange Pi 自带的 `orangepi-zram-config.service`
重复初始化 zram，也会失败，一并停用（保留原厂的）。

## 5. 根分区空间偏小

镜像固定 6.89 GiB，8 GB 卡上可用约 1.7 GiB。原因：

- Chromium snap 占约 1 GB
- 中文字体（`fonts-noto-cjk-extra`）约 300 MB
- XFCE 桌面与多媒体包

`orangepi-resize-filesystem.service` 会在首次开机把分区扩到整卡，
但 8 GB 卡本身没有多少余量。若要装更多软件，**建议用 16 GB 及以上的卡**，
或构建时调大镜像尺寸（`sdk/config/...` 里的 `IMAGE_SIZE`）。

## 6. HDMI 未验证

验收时显示器未连接，`/sys/class/drm/card*-HDMI-A-*/status` 为 `disconnected`。
因此 **2K/4K 输出能力没有实测证据**，只能确认：

- 6.1 内核的 DRM/KMS 驱动正常加载
- Panfrost 已接管 Mali-G31
- 设备树里 Mali 节点是禁用的，`customize-image.sh` 通过 `/boot/fixup.scr`
  在 U-Boot 阶段置为 `okay`（见下）

```bash
# /boot/fixup.cmd → fixup.scr
fdt set /soc/gpu@1800000 status okay
```

若 HDMI 无信号，先按 [VERIFY.md](VERIFY.md) 采集 `status`、`modes`、`edid`，
再判断是线材/显示器问题还是驱动问题。

## 7. 默认密码

镜像内置 `orangepi` / `orangepi`，且 SSH 允许密码登录。**上公网前务必改掉**：

```bash
passwd
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
```
