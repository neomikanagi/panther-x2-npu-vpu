# --- px2lab trial head (runs only after the one-shot flag was wiped) ---
setenv px2_part ${devnum}:${distro_bootpart}
setenv load_addr 0x09000000
# Hand U-Boot-side register state to Linux: WDT regs at +0x000, CRU GLB_* (0xc0-0xe0, GLB_RST_ST last) at +0x100,
# written to eMMC sector 0x6001 (read back with `px2lab status`).
mw.l 0x0c200000 0 0x80
cp.l 0xfe600000 0x0c200000 0x40
cp.l 0xfdd200c0 0x0c200100 0x9
mmc write 0x0c200000 0x6001 1
if load ${devtype} ${px2_part} ${load_addr} ${prefix}armbianEnv.txt; then
	env import -t ${load_addr} ${filesize}
fi
part uuid ${devtype} ${px2_part} partuuid
