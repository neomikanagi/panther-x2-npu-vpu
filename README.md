# panther-x2-npu-vpu

黑豹 X2（Panther X2，RK3566）在 **ophub 原版系统**上一条命令用上 NPU 和 VPU：换成 ophub 编译的 Rockchip BSP 内核（6.1）加修好的设备树，RKNN 和 MPP 装好即用。BSP 启动失败会自动退回原来的系统，不会变砖。也能一条命令转成 DietPi。

## 安装

1. 刷 ophub 原版镜像 [`Armbian_26.11.0_rockchip_panther-x2_trixie_6.18.57_server_2026.10.17.img.gz`](https://github.com/ophub/amlogic-s9xxx-armbian/releases/tag/Armbian_trixie_arm64_server_2026.10)，开机联网。
2. 以 root 运行：

```bash
curl -fsSL https://raw.githubusercontent.com/neomikanagi/panther-x2-npu-vpu/main/install.sh | sudo bash
```

3. `reboot`，回来后：

```bash
px2-npu-vpu status
px2-npu-vpu accept
```

`accept` 会在 NPU 上跑官方 mobilenet（必须识别出 156 号类别），用硬件解码 H.264/H.265/VP9 并与软件解码逐字节比对，再用硬件编码 H.264/H.265，全部通过显示 `ACCEPT PASS`。

要用 Python 跑 RKNN 的话，安装时加 `--with-python`（rknn-toolkit-lite2 装在 `/opt/px2-npu-vpu/venv`）：

```bash
curl -fsSL https://raw.githubusercontent.com/neomikanagi/panther-x2-npu-vpu/main/install.sh | sudo bash -s -- install --with-python
```

## 装好以后有什么

| | 内容 |
|---|---|
| NPU | RKNPU 驱动 0.9.8，`librknnrt` 2.5.0 在 `/usr/lib`，`rknn_api.h` 在 `/usr/include`；设备 `/dev/dri/renderD129` |
| VPU | MPP 1.1.0 在 `/usr/local`：H.264/H.265/VP9 解码，H.264/H.265 编码，JPEG 解码；`/dev/mpp_service` |
| RGA | 2D 加速，`/dev/rga` |
| USB | BSP 原版设备树没开 USB，这里打开了 |
| GPU | Mali-G52 由内核自带的 panfrost 驱动；盒子没有视频输出，NPU/VPU 用不到它 |

`/dev/mpp_service`、`/dev/rga`、`/dev/dma_heap/*` 归 video 组。NPU 调频固定 performance：它空闲时整块断电，不费电，默认的 ondemand 会让单路推理停在最低频。

作者在一台盒子上的实测：mobilenet_v1 约 10.7ms/帧；1080p 硬编 H.264/H.265 PSNR 43.9/45.4dB；1080p 硬解约 230（H.264）/ 400（H.265）/ 385（VP9）fps。

## 命令

| 命令 | 作用 |
|---|---|
| `px2-npu-vpu status` | 装了哪个版本、正在跑什么、设备在不在 |
| `px2-npu-vpu accept` | 硬件验收 |
| `px2-npu-vpu try [标签]` | 下一次启动只试一次这个版本，`accept` 通过才转正，失败自动回到原版本 |
| `px2-npu-vpu update` | 有新的正式版就 `try` 它 |
| `px2-npu-vpu uninstall` | 卸掉，回到 ophub 原版启动 |
| `px2boot status / enable / disable` | 默认启动 BSP 还是 ophub 主线 |
| `px2lab arm <标签>` | 下一次启动只走一次 `/boot/px2lab/trial-<标签>.scr`（调试用） |

## 为什么社区固件在有些盒子上开不了机

NPU 的 IOMMU 驱动比 RK809 PMIC 驱动先探测，探测时就给 NPU 电源域上电。如果 PMIC 这时还没打开 DCDC4（`vdd_npu`），总线握手失败，BSP 内核开机 5 秒 panic：`failed to get ack on domain 'npu'`。打开 NPU 的固件在 DCDC4 上电晚的盒子上都会撞上它（开机前用 i2c 关掉 DCDC4 可以次次复现）。这里给 IOMMU 节点加了指向 `vdd_npu` 的 `npu-supply`，内核的 fw_devlink 会等 PMIC 驱动起来再探测它。

## 怎么做到不变砖

U-Boot 先跑 `/boot/boot.scr.uimg`，它不启动内核就自动续跑 ophub 原来的 `/boot/boot.scr`，原启动路径不改。默认启动 BSP 前，U-Boot 先在 eMMC 引导空隙（扇区 `0x6002`）记下「待确认」并打开硬件看门狗；系统起来、网络和 SSH 就绪后 `px2boot-confirm.service` 记回「OK」。下次开机还是「待确认」就退回 ophub 主线并停在那里（`px2boot status` 显示 `ROLLED BACK`），失败那次的内核日志经 RAM（`0x110000` 的 ramoops）带回，存在 `/var/lib/px2-npu-vpu/logs/`。内核 panic 会 10 秒后重启，硬挂死由看门狗约 89 秒后复位。

## 跟进 ophub

`track-ophub` 每天检查 ophub 的 `kernel_rk35xx`，有新的 6.1.x 就自动构建成预发布版，标签就是内核版本（如 `k6.1.174`），一个内核一个版本。云端测不了硬件，所以预发布版在盒子上 `px2-npu-vpu try <标签>` 验收通过后再转成正式版；`install` 和 `update` 只拿正式版。

内核必须是 Rockchip BSP 分支：RKNN 和 MPP 都依赖它的驱动，主线内核不行。目前跟 6.1.x；ophub 也有 5.10 和 6.12 的 rk35xx 内核，没测过。

## 构建

`build/build.sh` 在 arm64 的 Debian 13 上运行（CI 用 `ubuntu-24.04-arm` + `debian:trixie` 容器）：下载并校验 ophub 内核包，用 `build/mkdtb.sh` 从 ophub 原版设备树派生（按路径找节点、核对稳压器名字，对不上就失败），编译 U-Boot 脚本和 MPP，生成验收用的测试码流。固定版本和哈希在 `versions.env`。

## 许可

本仓库脚本 MIT。内核来自 [ophub/kernel](https://github.com/ophub/kernel)（GPL-2.0，源码 [unifreq/linux-6.1.y-rockchip](https://github.com/unifreq/linux-6.1.y-rockchip)）；[MPP](https://github.com/rockchip-linux/mpp) 按其许可。RKNN 运行时受 Rockchip RKNN SDK 许可约束，发布包里不带，安装时从 [airockchip/rknn-toolkit2](https://github.com/airockchip/rknn-toolkit2) 的固定提交下载并校验。
