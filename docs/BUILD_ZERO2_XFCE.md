# Orange Pi Zero2 Ubuntu XFCE 构建记录

目标：Orange Pi Zero2（Allwinner H616）+ Ubuntu Jammy + XFCE + Orange Pi Linux 6.1 `next` 分支。

## 构建

本机使用 Docker Desktop，SDK 位于 `F:\workspace\orangerzero2\sdk`。在 PowerShell 中执行：

```powershell
docker build -t orangepi:zero2-build -f sdk\userpatches\Dockerfile sdk
docker run --rm --privileged `
  -v "${PWD}\sdk:/root/orangepi" `
  orangepi:zero2-build zero2-xfce
```

上述命令为原来的 Windows 挂载目录构建方式。2026-11-21 这轮已暂停该任务，改用 Docker 命名卷 `orangerzero2-sdk-linux`，卷在容器里仍挂到 `/root/orangepi`，以便 Kbuild 沿用原有对象和依赖路径。复制并校验后由 `scripts/resume-volume.sh` 续编。新容器名称为 `orangerzero2-ext4-build`，启动后可用 `docker logs --tail 20 orangerzero2-ext4-build` 查看日志。Windows 的 `sdk/output/images/` 接收最终 `.img` 和 `.sha256`；中间内核包保存在卷内的 `output/debs/`。

直接绑定 Windows 目录构建时，中间 deb 包也可在 Windows 的 `sdk/output/debs/` 看到。Ubuntu Ports 软件源使用华为云镜像，避免清华镜像连接波动。

Jammy 的 `chromium-browser` deb 只是启动器。数据卷构建使用 `scripts/prepare-chromium-seed.sh` 准备 ARM64 稳定版浏览器、`snapd` 和运行依赖，经 `snap debug validate-seed` 校验后，由 `sdk/userpatches/customize-image-host.sh` 将它们装入镜像。首次开机后可用 `snap wait system seed.loaded` 等待初始化，再用 `snap list chromium` 检查浏览器是否已安装。

这次构建包含：

- Linux 6.1 Orange Pi H616 `next` 分支；
- Ubuntu Jammy ARM64；
- XFCE；
- Chromium、Mesa/Panfrost 验证工具；
- V4L2/Cedrus、GStreamer、FFmpeg 和 EDID/DRM 验证工具；
- AW859A Wi‑Fi/蓝牙所需的 SDK 模块和固件；
- zram，缓解 512 MB/1 GB 内存运行桌面时的内存压力。

## 写卡和首次验证

1. 构建完成后，记录 `output/images/*.img` 的文件名和 SHA256：

   ```powershell
   Get-FileHash sdk\output\images\*.img -Algorithm SHA256
   ```

2. 关闭 Orange Pi，取出 TF 卡，用 Balena Etcher 或 Raspberry Pi Imager 选择整个 `.img` 文件并写入 TF 卡。不要只复制 `/boot`，也不要选择 SPI NOR；当前板上的 SPI NOR 是 `mtdblock0`，只有 2 MB。
3. 写卡完成后安全弹出 TF 卡，插回 Orange Pi，连接 5V/3A 电源、串口和 HDMI。串口参数为 `115200 8N1`，Windows 端口是 `COM5`。
4. HDMI 线建议在上电前就连接，显示器切到对应输入源；首次启动先不要手动指定 `disp_mode`，6.1 `next` 启动链使用 DRM/KMS 和显示器 EDID 自动选择模式。
5. 登录后通过串口执行：

```bash
sudo opi-display-check
glxinfo -B
v4l2-ctl --list-devices
chromium-browser --gpu-info 2>&1 | grep -E 'Graphics Feature|Video Decode|Compositing|OpenGL'
```

正常情况下，HDMI connector 应显示 `connected` 并列出显示器报告的模式；OpenGL renderer 应为 Panfrost/Mali-G31，而不是 `llvmpipe`。视频硬解是否被 Chromium 实际采用，要以 `chrome://gpu` 的 `Video Decode` 和播放测试为准。

## HDMI 无信号时保留的证据

通过 COM5 保存以下输出：

```bash
dmesg -T | grep -Ei 'drm|hdmi|edid|panfrost|cedrus|sunxi'
cat /sys/class/drm/card*-HDMI-A-*/status
cat /sys/class/drm/card*-HDMI-A-*/modes
```

如果 `status` 是 `disconnected` 或 EDID 为空，应优先检查 micro-HDMI 线材/转接头、显示器输入源和 5V/3A 电源；这类情况不是 XFCE 或 Chromium 配置问题。如果 connector 已连接但只有低分辨率，则根据 `modes` 和 EDID 输出调整显示器兼容模式。

## 2026-11-23 实板核对（8 GB 卡作 USB 根盘）

`COM5` 捕获到原卡 U-Boot；通过一次性内存环境加载新系统的 `Image`、`uInitrd`、DTB 和 `boot.scr`，未执行 `saveenv`。Linux 的 `/` 已确认是 USB 上新卡的 `/dev/sda1`（UUID `63c2f28d-bae2-43e7-882a-ef6fbdd1a59e`），原卡 UUID 为 `22483e1c-ea78-425b-a826-ae416e7c2154`。不要在新系统运行时拔读卡器。

- 新卡 ext4 完成日志回放后，离线 `e2fsck -fn` 通过，文件系统已覆盖现有分区。新卡已停用完成使命的首次扩容服务，并将 `bootlogo=false`、`verbosity=7` 用于诊断；原环境文件备份在新卡 `/boot/orangepiEnv.txt.pre-console-debug`。这些修改没有写回发布的 `.img`。
- 实测串口登录、以太网 (`172.16.2.218`)、XFCE 会话与 LightDM 正常；`DISPLAY=:0 glxinfo -B` 显示 `direct rendering: Yes` 和 `Mali-G31 (Panfrost)`。`wlan0` 已枚举但未关联 AP，蓝牙 `hci0` 已上电。Cedrus 的 `/dev/video0` 枚举了 MPEG-2、H.264、HEVC 和 VP8，未据此判定浏览器已硬解。
- 采用 NetworkManager 客户端模式，在新卡停用未配置的 `hostapd`、端口冲突的独立 `dnsmasq`、重复的 `zramswap`；原厂 zram swap 仍工作。HDMI 检测为未连接，未验证 2K/4K 输出。本次 USB 根盘测试不等于最终板载卡槽冷启动验收。

## 2026-11-23 板载卡槽冷启动验收

8 GB 卡装入板载卡槽后，`COM5` 自动登录；根分区为 `/dev/mmcblk0p1`，UUID `63c2f28d-bae2-43e7-882a-ef6fbdd1a59e`，整卡 `8054112256` 字节。内核 `6.1.31-sun50iw9`，LightDM 和 XFCE 会话运行，OpenGL 直接渲染为 `Mali-G31 (Panfrost)`。有线 DHCP 地址 `172.16.2.218`；Windows 收到 SSH 服务标识。Chromium `158.0.8127.36` 在普通用户下无头渲染本地测试页，返回预期标题并以 0 退出。此项未验证浏览器视频硬解。

板上恢复了 Ubuntu `snapd` 包指定的 `snap-confine` 文件能力，并从经过软件源校验的同版本 `systemd` 包恢复 `systemctl`。卡槽启动后还修复了 xrdp 因内存日志目录缺少 `/var/log/xrdp.log` 而起不来的问题：通过 `/etc/tmpfiles.d/zero2-xrdp-log.conf` 和 `xrdp.service.d/zero2-ramlog.conf` 在 ramlog 就绪后确保正确属主和权限。服务重启后 Windows 实测 TCP 3389 可达，`systemctl --failed` 为 0；未测试 RDP 图形登录。这些修复位于实体卡，不代表原 `.img` 已重新发布。验收时根分区可用约 1.7 GiB，HDMI 未连接。
