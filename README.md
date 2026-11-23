# Orange Pi Zero2 (H616) — Ubuntu Jammy + XFCE 镜像构建

一套可复现的构建方案，用于把 Orange Pi Zero2 做成一台带桌面、能跑 Chromium、
GPU 使用 Panfrost 加速的 Ubuntu 22.04 小主机。

本仓库**不包含**上游 SDK 源码、内核源码和镜像文件，只包含：

- 构建配置（板卡、发行版、桌面、软件包）
- 镜像定制脚本（GPU 设备树修复、Chromium snap 预置、诊断工具）
- 对上游 SDK 的两处必要补丁
- 构建 / 写卡 / 上板验证的脚本与文档

上游源码由 `build/bootstrap-sdk.sh` 按固定提交拉取。

## 已知可用组合

| 项目 | 版本 |
|---|---|
| 板卡 | Orange Pi Zero2（Allwinner H616，512 MB / 1 GB） |
| 上游 SDK | `orangepi-build` @ `7f24222b928eab94780f2af03289ce527e07241e`（2026-11-06） |
| 内核 | 6.1.31-sun50iw9（`next` 分支，U-Boot 2021.10-sunxi） |
| 发行版 | Ubuntu 22.04 Jammy（ARM64） |
| 桌面 | XFCE + LightDM |
| 浏览器 | Chromium 158（ARM64 snap，离线预置） |
| GPU | Mali-G31，通过 Panfrost 直接渲染 |
| 实际镜像大小 | 7,398,752,256 字节（约 6.89 GiB），建议 8 GB 及以上的卡 |

## 快速开始

任选其一：Docker（推荐，任何系统都能用）或原生 Linux。

### 方式 A：Windows + Docker

```powershell
git clone https://github.com/ghkjgod/zero2build.git
cd zero2build
.\build\bootstrap-sdk.ps1        # 在 WSL 里克隆 SDK、打补丁、装 overlay
.\tools\windows\build-zero2.ps1  # 构建镜像并打印 SHA256
```

> **必须放在 WSL2 的 ext4 上**（例如 `\\wsl$\Ubuntu\home\<user>\zero2build`）。
> 放在 `C:` / `F:` 的 NTFS 上，内核编译会慢一到两个数量级，也是最初卡住几小时的原因。
> 脚本检测到 NTFS 会警告并让你确认。

### 方式 B：Linux / macOS + Docker

```bash
git clone https://github.com/ghkjgod/zero2build.git
cd zero2build
./build/bootstrap-sdk.sh

docker build -t orangepi:zero2-build -f sdk/userpatches/Dockerfile sdk

# 先准备离线 Chromium snap seed（只需一次，约 1 GB 下载）
docker run --rm --privileged -v "$PWD/sdk:/root/orangepi" -v "$PWD:/repo:ro" \
  --entrypoint /bin/bash orangepi:zero2-build /repo/build/linux/prepare-chromium-seed.sh

docker run --rm --privileged \
  --cap-add=SYS_ADMIN --cap-add=MKNOD --cap-add=SYS_PTRACE \
  --security-opt apparmor=unconfined \
  -v "$PWD/sdk:/root/orangepi" \
  orangepi:zero2-build zero2-xfce
```

跳过 Chromium seed 也能构建成功，但镜像里不会预装浏览器（首次开机需要联网 snap 安装）。

### 方式 C：原生 Linux（最快）

```bash
git clone https://github.com/ghkjgod/zero2build.git
cd zero2build
./build/bootstrap-sdk.sh
sudo ./build/build-image.sh
```

要求 x86_64、ext4、约 25 GB 空闲空间。整体耗时约 1.5～3 小时（取决于 CPU 和网络）。

详细步骤、参数含义与排错见 [docs/BUILD.md](docs/BUILD.md)。

## 产物

```
sdk/output/images/Orangepizero2_3.1.0_ubuntu_jammy_desktop_xfce_linux6.1.31.img
sdk/output/images/Orangepizero2_3.1.0_ubuntu_jammy_desktop_xfce_linux6.1.31.img.sha256
```

已验证镜像的 SHA256：

```
fbb0b662436470f10d0a4355e401042d6118a33f27362d41073103cfc007ddb2
```

你自己重建出来的哈希**不会**相同（时间戳、随机种子不同），这是正常的；以上只用于核对
这次已实测的镜像。

## 写卡与上板

```powershell
# Windows，以管理员身份运行，先确认 Disk 编号确实是 TF 卡
.\tools\windows\flash-zero2.ps1 -DiskNumber 3 -Image .\sdk\output\images\xxxx.img
```

插回板载卡槽上电，默认账号：**`orangepi` / `orangepi`**（请登录后立刻 `passwd` 修改）。

串口参数 `115200 8N1`，无流控。首次开机后建议执行一次兜底检查：

```bash
sudo ./build/firstboot-fix.sh
```

新版镜像已在构建阶段处理了 snap 文件能力、xrdp 日志目录和网络服务冲突；
这个脚本对已修好的项目会自动跳过，可用于确认状态或修补旧镜像。
详见 [docs/KNOWN-ISSUES.md](docs/KNOWN-ISSUES.md)。

> **写卡时请开启校验。** 那次 8 GB 卡写入只有 4.84 MB/s 且关闭了写后校验，
> 结果板上 `systemctl` 出现静默损坏。慢速卡是无校验写卡最容易出问题的场景。

## 实测结果

在 8 GB TF 卡、板载卡槽冷启动条件下确认：

| 项目 | 结果 |
|---|---|
| 内核 | `6.1.31-sun50iw9` 正常启动，串口自动登录 |
| 桌面 | LightDM + XFCE 会话运行，`systemctl --failed` 为 0 |
| GPU | `glxinfo -B` → `direct rendering: Yes`，`Mali-G31 (Panfrost)` |
| Chromium | 158.0.8127.36，普通用户无头渲染本地页面成功 |
| 有线网络 | DHCP 获取地址，SSH 可登录 |
| 无线 | `wlan0` 已枚举，需自行 `nmcli device wifi connect` 关联热点 |
| 蓝牙 | `hci0` 已上电 |
| 视频解码 | Cedrus `/dev/video0` 枚举 H.264 / HEVC / VP8 / MPEG-2 |
| HDMI | **未实测**（验收时未接显示器） |

未验证项：2K/4K 实际输出、Chromium 播放视频时是否真正走硬解、蓝牙配对、RDP 图形登录。
这些都是需要在有显示器和外设的条件下人工确认的，见 [docs/VERIFY.md](docs/VERIFY.md)。

## 仓库结构

```
build/
  bootstrap-sdk.sh            拉取上游 SDK + 打补丁 + 安装 userpatches
  bootstrap-sdk.ps1           Windows 包装：把上面这步交给 WSL 执行
  build-image.sh              原生 Linux 一键构建
  firstboot-fix.sh            首次开机后的兜底修复与自检
  linux/
    prepare-chromium-seed.sh  生成离线 Chromium ARM64 snap seed
    resume-volume.sh          在 Docker 卷里断点续编（本机专用，含路径假设）
    repair-kernel-case.py     修复 Windows 检出导致的大小写冲突内核文件
sdk-overlay/
  patches/                    对上游 SDK 的补丁（debootstrap、loop 设备节点）
  userpatches/                构建配置与镜像定制脚本（SDK 构建时读取）
docs/
  BUILD.md                    完整构建说明、参数与排错
  KNOWN-ISSUES.md             已知问题与处理方式
  VERIFY.md                   上板验收清单
  BUILD_ZERO2_XFCE.md         原始构建记录与实板核对日志
tools/windows/
  build-zero2.ps1             Docker 构建入口（带 NTFS 检测）
  flash-zero2.ps1             带磁盘保护的写卡脚本
  zero2-console.ps1           通过串口执行命令并等待完成标记
CHANGELOG.md                  版本记录与修过的具体问题
```

## 许可

构建脚本与配置为本仓库原创，按 MIT 发布。上游 `orangepi-build`、Linux 内核、
U-Boot 及各类软件包遵循各自的原始许可。
