# 构建说明

本文覆盖从零开始重建这版 Zero2 镜像的完整流程、每个关键参数的用途，以及实际踩过的坑。

## 1. 环境准备

### 硬件与系统要求

| 项目 | 要求 |
|---|---|
| 架构 | x86_64（ARM 主机交叉编译链不适用此方案） |
| 磁盘 | 至少 25 GB 空闲；源码 + 工具链约 3 GB，内核构建峰值再占十几 GB |
| 文件系统 | **ext4 / btrfs / xfs**，不要用 NTFS（见下文） |
| 内存 | 8 GB 可用；内核并行编译会吃满 |
| 网络 | 首次需下载内核源码、U-Boot、rootfs 缓存和 Chromium snap（约 1 GB） |

### 为什么不能在 Windows 的 NTFS 上构建

最初这套构建直接绑定 `F:\workspace\orangerzero2\sdk` 进容器。结果是：内核编译阶段
I/O 等待时间远超 CPU 时间，几小时几乎没有进展，且反复出现 tar 解包挂起。

两个独立原因：

1. DrvFs/NTFS 上大量小文件的元数据操作极慢，Kbuild 每次生成 `.o`、`.cmd`、`.d` 都是多次系统调用。
2. Docker Desktop 的 TTY 在非交互运行时会让 `pv` 阻塞，导致 `pv | lz4 -dc | tar` 管道卡死——这一条已由补丁 `0001` 修复。

**结论**：源码放在 ext4 上。Windows 用户请放进 WSL2 的 ext4（`\\wsl$\Ubuntu\home\<user>\...`），
或者用 Docker 命名卷。本仓库最初最终采用的方案是命名卷 `orangerzero2-sdk-linux`，
把 Windows 上的旧树迁移进卷里再续编，避免重跑已完成的编译。

## 2. 拉取 SDK

```bash
./build/bootstrap-sdk.sh
```

脚本做三件事：

1. `git clone` 上游 `orangepi-xunlong/orangepi-build`；
2. `git checkout --detach 7f24222b928eab94780f2af03289ce527e07241e`——这是本方案验证过的提交；
3. 应用 `sdk-overlay/patches/*.patch`，并把 `sdk-overlay/userpatches/` 覆盖到 `sdk/userpatches/`。

补丁脚本是幂等的：已应用的补丁会跳过，反向校验不通过、正向也打不上时直接报错退出，
不会留下半套改动。

### `sdk-overlay/userpatches/` 里的文件

| 文件 | 作用 |
|---|---|
| `config-zero2-xfce.conf` | 构建配置，`./build.sh zero2-xfce` 时按这个名字查找 |
| `Dockerfile` | 构建容器；已把 Ubuntu 源换成清华镜像 |
| `customize-image.sh` | chroot 内执行：zram 参数、`opi-display-check`、Mali 节点 fixup、`panfrost` 自加载 |
| `customize-image-host.sh` | host 侧执行：把 Chromium snap seed 拷进镜像 |
| `cli/_all_distributions/main/packages` | 额外安装的验证工具（EDID、Vulkan、GStreamer、ffmpeg 等） |

### 配置逐项说明

```bash
BOARD="orangepizero2"          # H616 板卡
BRANCH="next"                  # 对应 Linux 6.1.31，U-Boot 2021.10-sunxi
RELEASE="jammy"                # Ubuntu 22.04
BUILD_OPT="image"              # 产出完整 .img
BUILD_DESKTOP="yes"
DESKTOP_ENVIRONMENT="xfce"
DESKTOP_APPGROUPS_SELECTED="browsers 3dsupport multimedia"
KERNEL_CONFIGURE="no"          # 用板卡仓库自带 .config，不进 menuconfig
COMPRESS_OUTPUTIMAGE="no"      # 不压缩，方便直接校验和写卡
NO_APT_CACHER="yes"            # 容器内不需要 apt-cacher-ng
DOWNLOAD_MIRROR="china"
CHINA_DOWNLOAD_MIRROR="huawei" # Ubuntu Ports 走华为云
DEST_LANG="zh_CN.UTF-8"
CLEAN_LEVEL="debs,oldcache"    # 保留 deb，便于复用到下一轮
```

`BRANCH=next` 与 `legacy` 的区别：`legacy` 是 4.9 老内核，`next` 是 6.1。只有 6.1
才有可用的 Panfrost（Mali-G31）和 Cedrus 主线驱动，所以这里必须用 `next`。

## 3. 构建

### 原生 Linux

```bash
sudo ./build/build-image.sh
```

分四个阶段：Chromium seed → 内核/U-Boot deb → 根文件系统 → 组装 `.img`。
内核 deb 已存在时会跳过编译，可安全重复执行。

### Docker

```bash
docker build -t orangepi:zero2-build -f sdk/userpatches/Dockerfile sdk
docker run --rm --privileged \
  --cap-add=SYS_ADMIN --cap-add=MKNOD --cap-add=SYS_PTRACE \
  --security-opt apparmor=unconfined \
  -v "$PWD/sdk:/root/orangepi" \
  orangepi:zero2-build zero2-xfce
```

Chromium seed 需要在容器内先跑一次 `prepare-chromium-seed.sh`；Docker 方式下推荐这样：

```bash
docker run --rm --privileged -v "$PWD/sdk:/root/orangepi" -v "$PWD:/repo:ro" \
  --entrypoint /bin/bash orangepi:zero2-build /repo/build/linux/prepare-chromium-seed.sh
```

### 预期耗时

| 阶段 | 时间 |
|---|---|
| 下载源码与工具链 | 10～30 分钟（取决于网络） |
| 内核 + U-Boot 编译 | 40～90 分钟 |
| rootfs 与桌面包安装 | 20～40 分钟 |
| 组装镜像 | 5～15 分钟 |

首次完整构建 1.5～3 小时。之后只改 `userpatches/` 里的定制脚本时，可用
`BUILD_OPT=image CLEAN_LEVEL=` 在几分钟内重新组装镜像。

## 4. 两处上游补丁

### `0001-debootstrap-docker-tty-and-fonts.patch`

改动 `scripts/debootstrap.sh`：

- 去掉 `pv` 管道，直接 `lz4 -dc | tar`，并用 `PIPESTATUS` 判断两个进程的退出码。
  原写法在 Docker 非交互 TTY 下会永久阻塞。
- `losetup -P` 失败时给出明确错误，而不是静默继续。
- 把 `${PIPESTATUS[0]}` 改成先保存到 `EVALPIPE` 再判断——`eval` 之后的 `PIPESTATUS`
  已经被重置，原判断其实拿不到 chroot 的退出码。
- 在 `TMPDIR` 位于镜像内时预先创建该目录。
- 支持离线预置 `fonts-noto-cjk-extra`：中文字体包较大，从华为云下载偶发中断；
  缓存到 `tmp/apt-cache/` 后先校验 SHA256 再喂给 chroot 的 apt。

### `0002-image-helpers-loop-partition-node.patch`

改动 `scripts/image-helpers.sh`：WSL 内核会在 sysfs 里注册 `loop0p1`，但不运行 udev，
所以 `/dev/loop0p1` 这个节点不存在，`mount` 直接失败。补丁从
`/sys/class/block/<dev>/dev` 读出 major:minor 自行 `mknod`。

## 5. Chromium 为什么要单独处理

Jammy 的 `chromium-browser` deb 只是一个十几行的启动器，真正浏览器只有 snap 版。
而板子首次开机往往没有稳定网络，所以镜像里必须预置。

`build/linux/prepare-chromium-seed.sh` 的做法：

1. 在构建机上装 `snapd` 和 `squashfs-tools`，取出 `snap` 命令；
2. 用 Canonical 的 `generic-classic.model`（固定 blob hash 校验）作为 classic seed 的模型；
3. 查 snapcraft API，按 **arm64 / stable** 递归解析 `chromium` 及其 base、default-provider；
4. `snap prepare-image --classic --arch=arm64` 下载并做签名校验；
5. `snap debug validate-seed` 校验，再确认 chromium 的 `architectures` 含 `arm64`。

产出写到 `sdk/tmp/chromium-arm64-seed/seed/`，由 `customize-image-host.sh` 拷进镜像的
`/var/lib/snapd/seed/`。首次开机 snapd 会据此离线安装，无需网络。

实测约 8 个包、976 MiB。

## 6. 排错

### 构建卡住不动

先看是不是 `pv`。若日志停在 `Extracting ...`，确认补丁 `0001` 已应用：

```bash
git -C sdk diff --stat -- scripts/debootstrap.sh
```

### `losetup` / `mount` 报找不到分区

WSL 下没有 `/dev/loopNpM`，确认补丁 `0002` 已应用，或手动：

```bash
cat /sys/class/block/loop0p1/dev    # 例如 7:1
mknod /dev/loop0p1 b 7 1
```

### apt 下载超时

默认走华为云。若换网络环境，改 `config-zero2-xfce.conf` 里的 `CHINA_DOWNLOAD_MIRROR`，
或者缓存 deb 到 `sdk/tmp/apt-cache/` 复用。

### 盘空间不足

`CLEAN_LEVEL=debs,oldcache` 会保留 deb。空间紧张时改成 `CLEAN_LEVEL=debs` 并清理
`sdk/output/` 下旧镜像。

### 镜像能启动但服务报错

这属于已知问题，不是构建失败。见 [KNOWN-ISSUES.md](KNOWN-ISSUES.md)。

## 7. 断点续编

`build/linux/resume-volume.sh` 是本机专用的脚本，里面写死了
`/root/orangepi`、`/export`、`/task-scripts` 等容器内路径和 `linux-image-next-sun50iw9_3.1.0_arm64.deb`
这个具体文件名。它的用途是：把已经编译好的树迁进 ext4 卷、修复 Windows 检出造成的
大小写冲突和 CRLF，然后只跑剩下的 image 阶段。

**在新机器上不需要它**——直接 `build-image.sh` 从零构建即可。保留它是为了记录
迁移过程做了哪些修补（尤其是 `repair-kernel-case.py`：Windows 文件系统不区分大小写，
内核源码里 `foo.c` 和 `Foo.c` 会互相覆盖，必须从 git blob 还原）。
