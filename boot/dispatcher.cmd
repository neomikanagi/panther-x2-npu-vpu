# px2lab one-shot dispatcher. Installed as /boot/boot.scr.uimg (root of p1).
#
# The stock U-Boot loop tries boot.scr.uimg before boot.scr and, if this
# script returns for any reason, prints "SCRIPT FAILED: continuing..." and
# runs the untouched boot.scr. So the normal boot path is never edited.
#
# A trial runs only when eMMC sector 0x6000 starts with "PX2LAB01", and only
# after that sector has been wiped. A hang or a watchdog reset therefore comes
# back through the normal boot.scr. U-Boot's mmc command takes hex numbers.
setenv px2_buf 0x0c000000
setenv px2_mag 0x0c001000
setenv px2_mag1 0x0c001004
setenv px2_trial 0x0c100000
if test "${devtype}" = "mmc"; then
	if mmc dev ${devnum}; then
		if mmc read ${px2_buf} 0x6000 1; then
			mw.l ${px2_mag} 0x4c325850 1
			mw.l ${px2_mag1} 0x31304241 1
			if cmp.l ${px2_buf} ${px2_mag} 2; then
				echo "px2lab: one-shot flag set"
				mw.l ${px2_buf} 0 0x80
				if mmc write ${px2_buf} 0x6000 1; then
					echo "px2lab: flag wiped, loading px2lab/trial.scr"
					if load ${devtype} ${devnum}:${distro_bootpart} ${px2_trial} ${prefix}px2lab/trial.scr; then
						source ${px2_trial}
					fi
				fi
			fi
		fi
	fi
fi

# --- px2boot: default BSP boot with rollback ---
# Sector 0x6002 = "PX2BOOT1" + state. OKAY: write PEND, boot bsp/default.scr;
# Linux writes OKAY back once the system is up (px2boot-confirm.service).
# PEND at boot time means the last BSP boot never got there: write FAIL and
# hand over to boot.scr (mainline), and stay there until `px2boot enable`.
# No magic, FAIL, or any failed step: boot.scr.
setenv px2_buf2 0x0c000008
setenv px2_mag2 0x0c001008
setenv px2_go 0
if test "${devtype}" = "mmc"; then
	if mmc dev ${devnum}; then
		if mmc read ${px2_buf} 0x6002 1; then
			mw.l ${px2_mag} 0x42325850 1
			mw.l ${px2_mag1} 0x31544f4f 1
			mw.l ${px2_mag2} 0x59414b4f 1
			if cmp.l ${px2_buf} ${px2_mag} 3; then
				setenv px2_go 1
			fi
			mw.l ${px2_mag2} 0x444e4550 1
			if cmp.l ${px2_buf} ${px2_mag} 3; then
				echo "px2boot: last BSP boot was never confirmed, rolling back to boot.scr"
				mw.l ${px2_buf2} 0x4c494146 1
				mmc write ${px2_buf} 0x6002 1
			fi
		fi
	fi
fi
if test "${px2_go}" = "1"; then
	mw.l ${px2_buf2} 0x444e4550 1
	if mmc write ${px2_buf} 0x6002 1; then
		echo "px2boot: state PEND, loading bsp/default.scr"
		if load ${devtype} ${devnum}:${distro_bootpart} ${px2_trial} ${prefix}bsp/default.scr; then
			source ${px2_trial}
		fi
	fi
fi
echo "px2lab: no trial, handing over to boot.scr"
