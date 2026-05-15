#!/bin/sh
# written by majad qureshi at lut .fi

DIR="/tmp/matrix-flash"
REQ="$DIR/request"
RUNNING="$DIR/running"
LOG="$DIR/status.log"
FLASH="/tmp/matrix_flash_inactive.sh"

mkdir -p "$DIR"

echo "Matrix flash runner ready." > "$LOG"

while true; do
	if [ -f "$REQ" ]; then
		rm -f "$REQ"

		if [ -f "$RUNNING" ]; then
			echo "Flash already running." >> "$LOG"
			sleep 1
			continue
		fi

		touch "$RUNNING"

		{
			echo "======================================="
			echo "Flash started: $(date)"
			echo "======================================="

			if [ ! -x "$FLASH" ]; then
				echo "ERROR: $FLASH not found or not executable"
				rm -f "$RUNNING"
				continue
			fi

			"$FLASH"

			echo "Flash script exited unexpectedly."
			echo "If flashing succeeded, router should have rebooted."
		} >> "$LOG" 2>&1

		rm -f "$RUNNING"
	fi

	sleep 1
done
