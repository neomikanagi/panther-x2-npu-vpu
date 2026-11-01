# --- px2lab trial boot: @KERNEL@ / @INITRD@ / @DTB@, tag @TAG@ ---
setenv bootargs "root=${rootdev} rootwait rootfstype=${rootfstype} rootflags=${rootflags} @CONSOLE@ consoleblank=0 ubootpart=${partuuid} ${extraargs} ${extraboardargs} cgroup_enable=cpuset cgroup_memory=1 cgroup_enable=memory swapaccount=1 @ARGS@ @MARK@"
if load ${devtype} ${px2_part} ${ramdisk_addr_r} ${prefix}@INITRD@; then
	if load ${devtype} ${px2_part} ${kernel_addr_r} ${prefix}@KERNEL@; then
		if load ${devtype} ${px2_part} ${fdt_addr_r} ${prefix}@DTB@; then
			fdt addr ${fdt_addr_r}
			fdt resize 65536
			if load ${devtype} ${px2_part} ${load_addr} ${prefix}overlay-user/px2-ramoops.dtbo; then
				if fdt apply ${load_addr}; then
					echo "px2lab: ramoops overlay applied"
				else
					load ${devtype} ${px2_part} ${fdt_addr_r} ${prefix}@DTB@
					fdt addr ${fdt_addr_r}
					fdt resize 65536
				fi
			fi
			# Arm dw_wdt @0xfe600000 (tclk 24 MHz): TOP=TOP_INIT=15 -> 2^31 ticks ~ 89 s.
			# CR = EN | RMOD=0 (reset on first timeout), RPL kept at its reset value 2, as Linux does; then kick.
			# A kernel that hangs before its own watchdog driver runs is reset back
			# to the normal boot.scr, because the flag is already gone.
			mw.l 0xfe600004 0xff
			mw.l 0xfe600000 0x09
			mw.l 0xfe60000c 0x76
			echo "px2lab: watchdog armed, booting @TAG@"
			booti ${kernel_addr_r} ${ramdisk_addr_r} ${fdt_addr_r}
		fi
	fi
fi
echo "px2lab: trial @TAG@ returned, falling back to boot.scr"
