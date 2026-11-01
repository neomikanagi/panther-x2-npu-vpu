#!/bin/bash
# Derive the Panther X2 accel DTB from ophub's unmodified rk3566-panther-x2.dtb.
# Only flips what the Rockchip SDK board files do (status, supplies, IRQ name);
# nothing about DDR, CPU or display. Nodes are found by path and checked by
# regulator name, so a kernel whose DTB moved things fails here, not at boot.
#   mkdtb.sh <ophub.dtb> <out.dtb>
set -euo pipefail
in=$1
out=$2
die() { echo "mkdtb: $*" >&2; exit 1; }

phandle_of() { # path expected-regulator-name
	[ "$(fdtget "$in" "$1" regulator-name 2>/dev/null)" = "$2" ] || die "$1 is not $2"
	fdtget -t x "$in" "$1" phandle
}
vdd_cpu=$(phandle_of /i2c@fdd40000/regulator@1c vdd_cpu)
vdd_logic=$(phandle_of /i2c@fdd40000/pmic@20/regulators/DCDC_REG1 vdd_logic)
vdd_npu=$(phandle_of /i2c@fdd40000/pmic@20/regulators/DCDC_REG4 vdd_npu)

nodes=(
	# NPU, its IOMMU and bus
	npu@fde40000 iommu@fde4b000 bus-npu
	# MPP: service, decoders, encoders, JPEG, IEP and their IOMMUs
	mpp-srv vdpu@fdea0400 iommu@fdea0800 vepu@fdee0000 iommu@fdee0800
	jpegd@fded0000 iommu@fded0480 iep@fdef0000 iommu@fdef0800
	rkvdec@fdf80200 iommu@fdf80800 rkvenc@fdf40000 iommu@fdf40f00
	# RGA2
	rk_rga@fdeb0000
	# USB host as mainline runs it: DWC3 in host mode on USB2 PHY0's OTG port
	usbdrd usbdrd/usb@fcc00000 usb2-phy@fe8a0000/otg-port
)
for n in "${nodes[@]}"; do
	fdtget "$in" "/$n" compatible > /dev/null 2>&1 || fdtget -p "$in" "/$n" > /dev/null 2>&1 ||
		die "node /$n missing"
done

cp "$in" "$out"
for n in "${nodes[@]}"; do
	fdtput -t s "$out" "/$n" status okay
done
fdtput -t s "$out" /npu@fde40000 interrupt-names npu_irq
fdtput -t x "$out" /npu@fde40000 rknpu-supply "$vdd_npu"
# The NPU IOMMU powers the NPU domain when it probes, before the RK809 driver
# switches vdd_npu (DCDC4) on. A PMIC that comes up with DCDC4 off then fails
# the bus-idle handshake and the BSP kernel panics ("failed to get ack on
# domain 'npu'"). Any *-supply phandle makes fw_devlink wait for the PMIC.
fdtput -t x "$out" /iommu@fde4b000 npu-supply "$vdd_npu"
fdtput -t x "$out" /bus-npu bus-supply "$vdd_logic"
fdtput -t x "$out" /bus-npu pvtm-supply "$vdd_cpu"
fdtput -t s "$out" /usbdrd/usb@fcc00000 dr_mode host
echo "mkdtb: $out (vdd_cpu=$vdd_cpu vdd_logic=$vdd_logic vdd_npu=$vdd_npu)"
