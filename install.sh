#!/bin/bash
# panther-x2-npu-vpu: Rockchip BSP kernel + working NPU/VPU on the Panther X2,
# on top of ophub Armbian (6.18 image) or DietPi converted from it.
#
#   curl -fsSL https://raw.githubusercontent.com/neomikanagi/panther-x2-npu-vpu/main/install.sh | sudo bash
#
# Once installed the same script is /usr/local/sbin/px2-npu-vpu:
#   install [--tag T] [--no-enable] [--with-python]   install a release (default: latest)
#   status                    what is installed and running
#   accept                    NPU/VPU hardware acceptance test
#   try [T]                   boot a release once as a trial; promote it only if accept passes
#   update                    try the latest release if it differs from the installed one
#   uninstall                 back to the plain ophub boot
set -euo pipefail
REPO=${PX2_REPO:-neomikanagi/panther-x2-npu-vpu}
STATE=/var/lib/px2-npu-vpu
SHARE=/usr/share/px2-npu-vpu
OPT=/opt/px2-npu-vpu

log() { echo "== $*"; }
die() { echo "px2-npu-vpu: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"

emmc_dev() {
	local b n
	for b in /sys/block/mmcblk[0-9]; do
		n=${b##*/}
		if [ "$(cat "$b/device/type" 2>/dev/null)" = MMC ] &&
			[ "$(cat "$b/${n}p1/start" 2>/dev/null)" = 32768 ]; then
			echo "/dev/$n"
			return
		fi
	done
}

check_box() {
	[ "$(uname -m)" = aarch64 ] || die "not aarch64"
	grep -qi panther /proc/device-tree/model 2>/dev/null || die "not a Panther X2"
	dev=$(emmc_dev)
	[ -n "$dev" ] || die "no eMMC with p1 at sector 32768 (expects the ophub layout)"
	findmnt -n -o SOURCE /boot | grep -q "${dev}p1$" || die "/boot is not ${dev}p1"
	[ -f /boot/boot.scr ] || die "/boot/boot.scr missing (expects the ophub boot)"
	# Sectors 0x6000-0x6002 in the gap between u-boot.itb and p1 hold the
	# one-shot flag, a U-Boot register dump and the default-boot state.
	if ! grep -q px2lab /boot/boot.scr.uimg 2>/dev/null; then
		[ -z "$(dd if="$dev" bs=512 skip=24576 count=3 status=none | tr -d '\0')" ] ||
			die "eMMC sectors 24576-24578 are in use; refusing"
	fi
	command -v curl > /dev/null || die "curl missing"
}

api() { curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/$1"; }

release_json() { # latest | newest (incl. prereleases) | <tag>
	case $1 in
	latest) api releases/latest ;;
	newest) api 'releases?per_page=1' ;;
	*) api "releases/tags/$1" ;;
	esac
}

fetch_release() { # tag dir -> prints payload path
	local json urls tarurl sumurl name
	json=$(release_json "$1") || die "release $1 not found in $REPO"
	urls=$(grep -o '"browser_download_url": *"[^"]*"' <<< "$json" | sed 's/.*"\(https[^"]*\)"/\1/')
	tarurl=$(grep '\.tar\.gz$' <<< "$urls" | head -1)
	sumurl=$(grep '/SHA256SUMS$' <<< "$urls" | head -1)
	[ -n "$tarurl" ] && [ -n "$sumurl" ] || die "release $1 has no payload"
	name=${tarurl##*/}
	mkdir -p "$2"
	curl -fsSL --retry 3 -o "$2/SHA256SUMS" "$sumurl"
	local bar=-s; [ -t 2 ] && bar=--progress-bar
	curl -fL --retry 3 $bar -o "$2/$name" "$tarurl" >&2
	(cd "$2" && sha256sum -c --quiet SHA256SUMS) >&2 || die "checksum mismatch for $name"
	echo "$2/$name"
}

set_overlay() {
	local env=/boot/armbianEnv.txt
	[ -f $env ] || return 0
	grep -q '^user_overlays=.*px2-ramoops' $env && return 0
	if grep -q '^user_overlays=$' $env; then
		sed -i 's/^user_overlays=$/user_overlays=px2-ramoops/' $env
	elif grep -q '^user_overlays=' $env; then
		sed -i 's/^user_overlays=\(.*\)$/user_overlays=\1 px2-ramoops/' $env
	else
		echo 'user_overlays=px2-ramoops' >> $env
	fi
}

install_rknn() { # runtime is under Rockchip's licence: fetched, not shipped
	. $SHARE/versions.env
	local rk=https://raw.githubusercontent.com/airockchip/rknn-toolkit2/$RKNN_COMMIT t
	t=$(mktemp -d)
	get() { curl -fsSL --retry 3 -o "$t/$3" "$rk/$1" && echo "$2  $t/$3" | sha256sum -c --quiet -; }
	get rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so "$RKNNRT_SHA256" librknnrt.so
	get rknpu2/runtime/Linux/librknn_api/include/rknn_api.h "$RKNN_API_H_SHA256" rknn_api.h
	get rknpu2/examples/rknn_api_demo/model/RK3566_RK3568/mobilenet_v1.rknn "$MOBILENET_SHA256" mobilenet_v1.rknn
	install -m 644 "$t/librknnrt.so" /usr/lib/librknnrt.so
	install -m 644 "$t/rknn_api.h" /usr/include/rknn_api.h
	install -D -m 644 "$t/mobilenet_v1.rknn" $OPT/models/mobilenet_v1.rknn
	rm -rf "$t"
}

install_python() { # rknn-toolkit-lite2 ships cp312 wheels only; Debian 13 has 3.13
	. $SHARE/versions.env
	local rk=https://raw.githubusercontent.com/airockchip/rknn-toolkit2/$RKNN_COMMIT/rknn-toolkit-lite2/packages
	local whl=rknn_toolkit_lite2-2.5.0-cp312-cp312-manylinux_2_17_aarch64.manylinux2014_aarch64.whl
	command -v uv > /dev/null || curl -LsSf https://astral.sh/uv/install.sh |
		env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh
	curl -fsSL --retry 3 -o "$OPT/$whl" "$rk/$whl"
	echo "$LITE2_WHL_SHA256  $OPT/$whl" | sha256sum -c --quiet -
	# Python itself under /opt: DietPi's installer wipes /root/.local.
	export UV_PYTHON_INSTALL_DIR=$OPT/python
	[ -x $OPT/venv/bin/python ] || uv venv -q -p 3.12 $OPT/venv
	VIRTUAL_ENV=$OPT/venv uv pip install -q "$OPT/$whl" numpy opencv-python-headless
	rm -f "$OPT/$whl"
}

install_payload() { # payload.tar.gz
	local p=$1 kver top
	# Only these top-level trees. On merged-/usr systems /lib, /bin, /sbin are
	# symlinks into /usr; a payload entry under them would let tar replace the
	# symlink with a directory and take the dynamic linker away.
	for top in $(tar -tzf "$p" | cut -d/ -f1 | sort -u); do
		case $top in boot | etc | opt | usr) ;; *) die "payload has unexpected top-level entry '$top'" ;; esac
	done
	tar -tzf "$p" | grep -v '/$' | sed 's|^|/|' > /tmp/px2-files.$$
	# --no-overwrite-dir: never touch the mode/owner of existing directories (/, /boot, /etc ...);
	# --keep-directory-symlink: never replace a symlink to a directory.
	tar -C / --no-overwrite-dir --keep-directory-symlink --no-same-owner -xzf "$p"
	mkdir -p $SHARE
	mv /tmp/px2-files.$$ $SHARE/files.txt
	. $SHARE/manifest.env
	kver=$KERNEL
	depmod -a "$kver"
	ldconfig
	set_overlay
	systemctl daemon-reload
	systemctl enable -q px2lab-guard.service px2boot-confirm.service
	udevadm control --reload || true
	mkdir -p $STATE/logs
}

cmd_install() {
	local tag=latest enable=1 python=0 file=''
	while [ $# -gt 0 ]; do
		case $1 in
		--tag) tag=$2; shift ;;
		--file) file=$2; shift ;;
		--no-enable) enable=0 ;;
		--with-python) python=1 ;;
		*) die "unknown option $1" ;;
		esac
		shift
	done
	check_box
	local dir=$STATE/download
	rm -rf "$dir"
	if [ -z "$file" ]; then
		log "downloading release $tag from $REPO"
		file=$(fetch_release "$tag" "$dir")
	fi
	log "installing $(basename "$file")"
	install_payload "$file"
	log "fetching the RKNN runtime"
	install_rknn
	if [ $python = 1 ]; then
		log "installing rknn-toolkit-lite2 (Python 3.12 venv in $OPT/venv)"
		install_python
	fi
	rm -rf "$dir"
	[ $enable = 1 ] && px2boot enable
	. $SHARE/manifest.env
	log "installed $TAG ($KERNEL). Reboot to boot it; then: px2-npu-vpu status / accept"
}

cmd_status() {
	if [ -f $SHARE/manifest.env ]; then
		. $SHARE/manifest.env
		echo "installed: $TAG ($KERNEL, MPP $MPP_TAG)"
	else
		echo "installed: nothing"
	fi
	px2boot status 2>/dev/null || true
	echo "devices: $(ls /dev/dri/renderD129 /dev/mpp_service /dev/rga 2>/dev/null | tr '\n' ' ')"
	[ -f $STATE/last-try ] && echo "last try: $(cat $STATE/last-try)"
	return 0
}

cmd_try() { # tag: boot it once from /boot/px2lab/cand, promote on PASS
	local tag=${1:-newest} dir=$STATE/cand file kver
	check_box
	rm -rf "$dir" /boot/px2lab/cand
	log "downloading release $tag"
	file=$(fetch_release "$tag" "$dir")
	mkdir -p /boot/px2lab/cand "$dir/x"
	tar -C "$dir/x" -xzf "$file" boot/bsp usr/share/px2-npu-vpu/manifest.env
	kver=$(. "$dir/x/usr/share/px2-npu-vpu/manifest.env" && echo "$KERNEL")
	cp "$dir/x/boot/bsp/Image" "$dir/x/boot/bsp/uInitrd" "$dir/x/boot/bsp/rk3566-panther-x2.dtb" /boot/px2lab/cand/
	tar -C / --no-overwrite-dir --keep-directory-symlink --no-same-owner -xzf "$file" "usr/lib/modules/$kver" boot/px2lab/trial-cand.scr
	depmod -a "$kver"
	rm -rf "$dir/x"
	cat > "$dir/check" <<EOF
#!/bin/bash
# Runs inside the candidate trial boot (px2lab-guard). PASS -> install it for good.
if [ "\$(uname -r)" = "$kver" ] && $OPT/bin/accept; then
	/usr/local/sbin/px2-npu-vpu install --file "$file" && echo "$tag PASS, promoted \$(date -Is)" > $STATE/last-try
else
	echo "$tag FAIL \$(date -Is)" > $STATE/last-try
fi
rm -rf /boot/px2lab/cand
EOF
	chmod 755 "$dir/check"
	sync
	px2lab arm cand
	log "armed: next boot tries $tag once ($kver) and promotes it only if accept passes. Reboot when ready."
}

cmd_update() {
	local latest
	latest=$(release_json latest | grep -o '"tag_name": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/')
	[ -n "$latest" ] || die "no release found"
	. $SHARE/manifest.env 2>/dev/null || TAG=
	if [ "$latest" = "$TAG" ]; then
		echo "up to date: $TAG"
	else
		cmd_try "$latest"
	fi
}

cmd_uninstall() {
	local dev
	dev=$(emmc_dev)
	px2boot disable 2>/dev/null || true
	systemctl disable -q px2lab-guard.service px2boot-confirm.service 2>/dev/null || true
	if [ -f $SHARE/files.txt ]; then
		xargs -d '\n' rm -f < $SHARE/files.txt
	fi
	rm -rf /boot/bsp /boot/px2lab /boot/boot.scr.uimg /boot/overlay-user/px2-ramoops.dtbo \
		$OPT $STATE $SHARE /usr/lib/librknnrt.so /usr/include/rknn_api.h
	[ -f /boot/armbianEnv.txt ] && sed -i 's/^\(user_overlays=.*\)px2-ramoops/\1/; s/^\(user_overlays=\) *$/\1/' /boot/armbianEnv.txt
	[ -n "$dev" ] && dd if=/dev/zero of="$dev" bs=512 seek=24576 count=3 conv=notrunc,fsync status=none
	systemctl daemon-reload
	ldconfig
	log "removed. The next boot is the plain ophub boot.scr."
}

cmd=${1:-install}
[ $# -gt 0 ] && shift
case $cmd in
install) cmd_install "$@" ;;
status) cmd_status ;;
accept) exec $OPT/bin/accept ;;
try) cmd_try "$@" ;;
update) cmd_update ;;
uninstall) cmd_uninstall ;;
*) sed -n '2,13p' "$0"; exit 2 ;;
esac
