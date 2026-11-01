#!/bin/bash
# Build the release payload on arm64 Debian 13 (CI: ubuntu-24.04-arm + debian:trixie).
#   build/build.sh [kernel_version]
# Needs: curl git build-essential cmake device-tree-compiler u-boot-tools ffmpeg
#        libjpeg-turbo-progs python3
# Output: dist/px2-npu-vpu-<kernel>-r<rev>.tar.gz, SHA256SUMS, NOTES.md, TAG
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
cd "$top"
. ./versions.env
kv=${1:-$KERNEL_VERSION}
if [ "$kv" != "$KERNEL_VERSION" ]; then
	# Not the pinned kernel: take the digest GitHub publishes for ophub's asset.
	KERNEL_SHA256=$(curl -fsSL https://api.github.com/repos/ophub/kernel/releases/tags/kernel_rk35xx |
		python3 -c 'import json,sys; v=sys.argv[1]; a=[x for x in json.load(sys.stdin)["assets"] if x["name"]==v+".tar.gz"]; print(a[0]["digest"].split(":")[1])' "$kv")
fi
kver=$kv-rk35xx-ophub
tag=k$kv
work=$top/work
root=$work/root
dist=$top/dist
rm -rf "$work" "$dist"
mkdir -p "$work" "$root" "$dist"

fetch() { # url sha out
	curl -fsSL --retry 3 -o "$3" "$1"
	echo "$2  $3" | sha256sum -c --quiet -
}

echo "== kernel $kver"
fetch "https://github.com/ophub/kernel/releases/download/kernel_rk35xx/$kv.tar.gz" "$KERNEL_SHA256" "$work/kernel.tar.gz"
tar -C "$work" -xzf "$work/kernel.tar.gz"
(cd "$work/$kv" && sha256sum -c --quiet sha256sums)
mkdir -p "$root/boot/bsp" "$root/boot/px2lab" "$root/boot/overlay-user" "$root/usr/lib/modules"
tar -C "$work" -xzf "$work/$kv/boot-$kver.tar.gz" "vmlinuz-$kver" "uInitrd-$kver"
tar -C "$work" -xzf "$work/$kv/dtb-rockchip-$kver.tar.gz" rk3566-panther-x2.dtb
install -m 644 "$work/vmlinuz-$kver" "$root/boot/bsp/Image"
install -m 644 "$work/uInitrd-$kver" "$root/boot/bsp/uInitrd"
install -m 644 "$work/rk3566-panther-x2.dtb" "$root/boot/px2lab/rk3566-panther-x2.stock.dtb"
bash build/mkdtb.sh "$work/rk3566-panther-x2.dtb" "$root/boot/bsp/rk3566-panther-x2.dtb"
# Debian 13 is merged-/usr: /lib is a symlink to usr/lib, so modules go under usr/.
tar -C "$root/usr/lib/modules" -xzf "$work/$kv/modules-$kver.tar.gz"
[ -d "$root/usr/lib/modules/$kver" ] || { echo "modules tarball has no $kver" >&2; exit 1; }

echo "== U-Boot scripts"
mkscr() { mkimage -q -C none -A arm64 -T script -n "$1" -d "$2" "$3"; }
mkscr px2-dispatcher boot/dispatcher.cmd "$root/boot/boot.scr.uimg"
dtc -q -@ -I dts -O dtb -o "$root/boot/overlay-user/px2-ramoops.dtbo" boot/px2-ramoops.dts
console="earlycon=uart8250,mmio32,0xfe660000 console=ttyS2,1500000n8 console=tty0"
trial_args="loglevel=8 ignore_loglevel panic=10 oops=panic softlockup_panic=1 hung_task_panic=1 pstore.compress=none"
bootscr() { # out tag mark kernel initrd dtb args
	local cmd=$work/$2.cmd
	cat boot/trial-head.cmd > "$cmd"
	sed -e "s|@TAG@|$2|g" -e "s|@MARK@|$3|g" -e "s|@KERNEL@|$4|g" -e "s|@INITRD@|$5|g" \
		-e "s|@DTB@|$6|g" -e "s|@CONSOLE@|$console|g" -e "s|@ARGS@|$7|g" boot/trial-boot.cmd >> "$cmd"
	mkscr "px2-$2" "$cmd" "$1"
}
bootscr "$root/boot/bsp/default.scr" bsp-default px2boot=bsp bsp/Image bsp/uInitrd \
	bsp/rk3566-panther-x2.dtb "loglevel=7 panic=10 softlockup_panic=1 pstore.compress=none"
bootscr "$root/boot/px2lab/trial-stock.scr" stock px2lab=stock bsp/Image bsp/uInitrd \
	px2lab/rk3566-panther-x2.stock.dtb "$trial_args"
bootscr "$root/boot/px2lab/trial-cand.scr" cand px2lab=cand px2lab/cand/Image px2lab/cand/uInitrd \
	px2lab/cand/rk3566-panther-x2.dtb "$trial_args"

echo "== MPP $MPP_TAG"
git clone -q --depth 1 -b "$MPP_TAG" https://github.com/rockchip-linux/mpp.git "$work/mpp"
cmake -S "$work/mpp" -B "$work/mpp/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_TEST=ON \
	-DCMAKE_INSTALL_PREFIX=/usr/local > /dev/null
make -C "$work/mpp/build" -j"$(nproc)" > /dev/null
make -C "$work/mpp/build" install DESTDIR="$root" > /dev/null
mpp_commit=$(git -C "$work/mpp" rev-parse HEAD)

echo "== NPU test tool (runtime fetched at install time)"
rk=https://raw.githubusercontent.com/airockchip/rknn-toolkit2/$RKNN_COMMIT
fetch "$rk/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so" "$RKNNRT_SHA256" "$work/librknnrt.so"
fetch "$rk/rknpu2/runtime/Linux/librknn_api/include/rknn_api.h" "$RKNN_API_H_SHA256" "$work/rknn_api.h"
fetch "$rk/rknn-toolkit2/examples/tflite/mobilenet_v1/dog_224x224.jpg" "$DOG_JPG_SHA256" "$work/dog.jpg"
mkdir -p "$root/opt/px2-npu-vpu/bin" "$root/opt/px2-npu-vpu/testdata"
gcc -O2 -Wall -I"$work" -o "$root/opt/px2-npu-vpu/bin/rknn_classify" tools/rknn_classify.c -L"$work" -lrknnrt
install -m 755 tools/accept.sh "$root/opt/px2-npu-vpu/bin/accept"

echo "== VPU test data"
td=$root/opt/px2-npu-vpu/testdata
djpeg -pnm "$work/dog.jpg" > "$td/dog.ppm"
ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }
ff -f lavfi -i testsrc2=size=1280x720:rate=30 -frames:v 30 -pix_fmt nv12 -f rawvideo "$work/src.nv12"
src=(-f rawvideo -pix_fmt nv12 -s 1280x720 -r 30 -i "$work/src.nv12")
ff "${src[@]}" -c:v libx264 -profile:v high -pix_fmt yuv420p "$td/t.h264"
ff "${src[@]}" -c:v libx265 -pix_fmt yuv420p -x265-params log-level=error "$td/t.hevc"
ff "${src[@]}" -c:v libvpx-vp9 -b:v 2M -pix_fmt yuv420p -f ivf "$td/t.vp9.ivf"
ff -f lavfi -i testsrc2=size=640x360:rate=30 -frames:v 10 -pix_fmt nv12 -f rawvideo "$td/t.nv12"
{
	for c in h264:t.h264 hevc:t.hevc vp9:t.vp9.ivf; do
		ff -i "$td/${c#*:}" -f rawvideo -pix_fmt nv12 "$work/sw.nv12"
		echo "MD5_${c%%:*}=$(md5sum < "$work/sw.nv12" | cut -c1-32)"
	done
	echo "ENC_W=640 ENC_H=360 ENC_N=10"
} > "$td/expected.env"

echo "== rootfs files"
cp -a rootfs/. "$root/"
install -m 755 install.sh "$root/usr/local/sbin/px2-npu-vpu"
chmod 755 "$root"/usr/local/sbin/*
mkdir -p "$root/usr/share/px2-npu-vpu"
cp versions.env "$root/usr/share/px2-npu-vpu/"
cat > "$root/usr/share/px2-npu-vpu/manifest.env" <<EOF
TAG=$tag
KERNEL=$kver
KERNEL_SHA256=$KERNEL_SHA256
MPP_TAG=$MPP_TAG
MPP_COMMIT=$mpp_commit
RKNN_COMMIT=$RKNN_COMMIT
SOURCE_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo unknown)
BUILT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

echo "== pack"
name=px2-npu-vpu-$kv.tar.gz
repo=${GITHUB_REPOSITORY:-neomikanagi/panther-x2-npu-vpu}
tar -C "$root" --owner=0 --group=0 --numeric-owner -czf "$dist/$name" boot etc opt usr
(cd "$dist" && sha256sum "$name" > SHA256SUMS)
echo "$tag" > "$dist/TAG"
cat > "$dist/NOTES.md" <<EOF
ophub \`$kver\` + NPU/VPU/RGA/USB device tree for the Panther X2, MPP $MPP_TAG.

Install on a box running ophub Armbian (6.18 image) or DietPi converted from it:

\`\`\`bash
curl -fsSL https://raw.githubusercontent.com/$repo/main/install.sh | sudo bash -s -- install --tag $tag
\`\`\`

Kernel package SHA-256: \`$KERNEL_SHA256\`. The NPU runtime (librknnrt) is not
included; install.sh downloads it from airockchip/rknn-toolkit2@$RKNN_COMMIT.
EOF
ls -l "$dist"
du -sh "$root"
