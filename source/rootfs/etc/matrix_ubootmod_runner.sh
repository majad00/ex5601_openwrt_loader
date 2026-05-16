#!/bin/sh
# written by majad qureshi at lut .fi

DIR="/tmp/matrix-ubootmod"
REQ="$DIR/request"
RUNNING="$DIR/running"
LOG="$DIR/status.log"
STAGER="/tmp/matrix_boot_initramfs.sh"

mkdir -p "$DIR"
echo "Matrix U-Boot layout runner ready." > "$LOG"

while true; do
	if [ -f "$REQ" ]; then
		rm -f "$REQ"

		if [ -f "$RUNNING" ]; then
			echo "U-Boot layout staging already running." >> "$LOG"
			sleep 1
			continue
		fi

		touch "$RUNNING"

		{
			echo "======================================="
			echo "U-Boot layout initramfs staging started: $(date)"
			echo "======================================="

			if [ ! -x "$STAGER" ]; then
				echo "ERROR: $STAGER not found or not executable"
				rm -f "$RUNNING"
				continue
			fi

			if [ ! -f /tmp/initramfs.bin ]; then
				echo "ERROR: /tmp/initramfs.bin not found"
				rm -f "$RUNNING"
				continue
			fi

			"$STAGER"

			echo "Stager exited ."
			echo "staging ends, router work in initramfs with auto scripting give it a min or two."
		} >> "$LOG" 2>&1

		rm -f "$RUNNING"
	fi

	sleep 1
done
