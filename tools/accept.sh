#!/bin/bash
# Hardware acceptance for the Panther X2 NPU/VPU, a minute or so, no ffmpeg needed.
#  NPU: official RK3566 mobilenet_v1 on the official dog picture must give class 156.
#  VPU: H.264/H.265/VP9 hardware decodes must match software decodes made at
#       build time (MD5); H.264/H.265 hardware encodes must decode back to all frames.
set -u
opt=/opt/px2-npu-vpu
td=$opt/testdata
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }

. "$td/expected.env"

out=$("$opt/bin/rknn_classify" "$opt/models/mobilenet_v1.rknn" "$td/dog.ppm" 20 2>&1)
top=$(sed -n 's/^top5: \[\([0-9]*\)\] \([0-9.]*\).*/\1 \2/p' <<< "$out")
ms=$(sed -n 's/^rknn_run: \([0-9.]*\) ms.*/\1/p' <<< "$out")
if [ "${top%% *}" = 156 ]; then ok "npu mobilenet_v1 class 156 p=${top#* } ${ms}ms"; else bad "npu: $out"; fi

for c in h264:7 hevc:16777220 vp9:10; do
	name=${c%%:*} type=${c##*:}
	file=$(ls "$td"/t."$name"* | head -1)
	mpi_dec_test -i "$file" -t "$type" -o "$tmp/$name.nv12" > "$tmp/dec-$name.log" 2>&1
	sum=$(md5sum < "$tmp/$name.nv12" 2>/dev/null | cut -c1-32)
	want=$(eval echo "\$MD5_$name")
	if [ "$sum" = "$want" ]; then ok "vpu decode $name bit-exact"; else bad "vpu decode $name: $sum != $want"; fi
done

frame=$((ENC_W * ENC_H * 3 / 2))
for c in h264:7 hevc:16777220; do
	name=${c%%:*} type=${c##*:}
	mpi_enc_test -i "$td/t.nv12" -w "$ENC_W" -h "$ENC_H" -f 0 -t "$type" -n "$ENC_N" \
		-o "$tmp/e.$name" > "$tmp/enc-$name.log" 2>&1
	mpi_dec_test -i "$tmp/e.$name" -t "$type" -o "$tmp/e.$name.nv12" > /dev/null 2>&1
	n=$(( $(stat -c %s "$tmp/e.$name.nv12" 2>/dev/null || echo 0) / frame ))
	if [ "$n" = "$ENC_N" ]; then ok "vpu encode $name $n frames"; else bad "vpu encode $name: $n of $ENC_N frames"; fi
done

[ $fail = 0 ] && echo "ACCEPT PASS" || echo "ACCEPT FAIL"
exit $fail
