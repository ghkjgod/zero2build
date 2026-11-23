# 上板验收清单

按顺序执行，任一步不符合预期就在该步停下排查。所有命令都可以通过串口
（`115200 8N1`）或 SSH 执行。

## 0. 前提

- 8 GB 及以上 TF 卡，写卡**开启校验**
- 5V/3A 电源（供电不足会表现为 HDMI 花屏、USB 掉盘、Wi-Fi 断连）
- 串口线接在板子的调试口上，电脑侧端口号按实际填写

## 1. 启动

```bash
uname -r                 # 期望 6.1.31-sun50iw9
findmnt -no SOURCE /     # 期望 /dev/mmcblk0p1（板载卡槽）
lsblk -bdno SIZE /dev/mmcblk0   # 与卡容量一致
```

串口应该出现 `orangepizero2 login:`，用 `orangepi` / `orangepi` 登录。

## 2. 首次修复

```bash
sudo ./build/firstboot-fix.sh
systemctl --failed        # 期望 "0 loaded units listed"
```

## 3. 桌面与 GPU

```bash
systemctl is-active lightdm
pgrep -a xfce4-session
DISPLAY=:0 glxinfo -B | grep -E 'direct rendering|OpenGL renderer'
```

期望：

```
direct rendering: Yes
OpenGL renderer string: Mali-G31 (Panfrost)
```

若是 `llvmpipe`，说明 Panfrost 没绑定，检查：

```bash
lsmod | grep panfrost
cat /sys/class/drm/card0/device/of_node/status 2>/dev/null
dmesg | grep -i -E 'panfrost|mali'
```

Mali 节点默认在设备树里是 `disabled`，由 `/boot/fixup.scr` 在 U-Boot 阶段置为 `okay`。
若 `lsmod` 没有 panfrost，先确认 `/boot/fixup.scr` 存在且 `orangepiEnv.txt` 里没有覆盖它。

## 4. Chromium

```bash
snap list chromium
chromium --version
```

以普通用户跑一次无头渲染，确认 snap 沙箱能正常工作：

```bash
chromium --headless --no-first-run --disable-background-networking \
  --user-data-dir=/tmp/cr-test --dump-dom 'data:text/html,<title>OK</title>' | grep -o '<title>OK</title>'
```

若报 `snap-confine is packaged without necessary permissions`，见
[KNOWN-ISSUES.md](KNOWN-ISSUES.md) 第 1 项。

## 5. 视频硬解

```bash
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video0 --list-formats-out
```

期望能看到 Cedrus 设备，输出格式含 H.264 / HEVC。

**注意**：`/dev/video0` 枚举出格式只能证明内核解码器存在，**不能**证明浏览器在用它。
要确认硬解，需要看播放时的实际负载：

```bash
# 播放 1080p H.264 时观察 CPU
top -b -n 1 | head -12
```

若 4 个核里解码相关占用很低（单核 < 30%），才说明走的是硬件解码。
也可以用 `chrome://gpu` 页面的 `Video Decode` 字段辅助判断。

## 6. HDMI（本方案未验证）

```bash
sudo opi-display-check
```

或手动：

```bash
cat /sys/class/drm/card*-HDMI-A-*/status    # 期望 connected
cat /sys/class/drm/card*-HDMI-A-*/modes     # 期望列出 1920x1080、2560x1440、3840x2160 等
```

判读：

| 现象 | 处理 |
|---|---|
| `status` 为 `disconnected` | 先查线材/转接头/显示器输入源，再查供电 |
| `status` 为 `connected` 但 `modes` 很短或不含目标分辨率 | 显示器 EDID 没读到，换线或换显示器复测 |
| `modes` 有目标分辨率但实际输出不对 | 手工指定模式：改 `/boot/orangepiEnv.txt` 里的 `disp_mode` |

`orangepiEnv.txt` 默认是 `disp_mode=1920x1080p60`。想让 6.1 内核按 EDID 自动选模式，
把这行注释掉即可（`next` 分支走 DRM/KMS，不再依赖 U-Boot 的固定模式）。

## 7. 网络

```bash
nmcli -t -f DEVICE,TYPE,STATE dev
ip -br -4 addr
```

有线应通过 DHCP 拿到地址。无线需要手工连：

```bash
nmcli device wifi list
sudo nmcli device wifi connect '<SSID>' password '<密码>'
```

## 8. 蓝牙

```bash
rfkill list
bluetoothctl show | grep -E 'Controller|Powered'
bluetoothctl scan on
```

## 9. 远程桌面

```bash
systemctl is-active xrdp xrdp-sesman
ss -ltn | grep 3389
```

从电脑上 `mstsc` 连接 `<板子IP>:3389`，登录 `orangepi` / `orangepi`。
本方案只验证了端口可达，**图形会话未实测**。

## 10. 稳定性观察

至少留观 30 分钟，确认：

```bash
dmesg -T | grep -iE 'error|fail|timeout|I/O error' | tail -20
uptime
free -m
df -h /
```

重点看有没有 `EXT4-fs error`、`I/O error`、`oom-kill`。慢速卡 + 无写后校验
最容易出现这类问题。
