#!/bin/sh
# written by majad qureshi at lut.fi
# Matrix U-Boot layout runner with stager log capture

DIR="/tmp/matrix-ubootmod"
REQ="$DIR/request"
RUNNING="$DIR/running"
LOG="$DIR/status.log"

# Stager script path. Keep this path stable for UI/button/trigger logic.
STAGER="${STAGER:-/tmp/matrix_boot_initramfs.sh}"

# The stager has its own "exec > $LOG 2>&1", so we force it to log here
# and tail that file into the runner status log.
STAGER_LOG="$DIR/stager.log"

mkdir -p "$DIR"
echo "Matrix U-Boot layout runner ready: $(date)" > "$LOG"
echo "Runner log: $LOG" >> "$LOG"
echo "Stager log: $STAGER_LOG" >> "$LOG"
echo "Stager: $STAGER" >> "$LOG"

stop_tail() {
	if [ -n "${TAIL_PID:-}" ]; then
		kill "$TAIL_PID" 2>/dev/null || true
		wait "$TAIL_PID" 2>/dev/null || true
		TAIL_PID=""
	fi
}

while true; do
	if [ -f "$REQ" ]; then
		rm -f "$REQ"

		if [ -f "$RUNNING" ]; then
			echo "U-Boot layout staging already running: $(date)" >> "$LOG"
			sleep 1
			continue
		fi

		touch "$RUNNING"

		{
			echo ""
			echo "======================================="
			echo "U-Boot layout initramfs staging started: $(date)"
			echo "======================================="
			echo "STAGER=$STAGER"
			echo "STAGER_LOG=$STAGER_LOG"
			echo "INITRAMFS=${INITRAMFS:-/tmp/initramfs.bin}"
			echo "NO_REBOOT=${NO_REBOOT:-0}"
			echo ""
		} >> "$LOG" 2>&1

		if [ ! -x "$STAGER" ]; then
			echo "ERROR: $STAGER not found or not executable" >> "$LOG"
			rm -f "$RUNNING"
			sleep 1
			continue
		fi

		if [ ! -f "${INITRAMFS:-/tmp/initramfs.bin}" ]; then
			echo "ERROR: ${INITRAMFS:-/tmp/initramfs.bin} not found" >> "$LOG"
			rm -f "$RUNNING"
			sleep 1
			continue
		fi

		# Prepare a fresh stager log and mirror it into status.log while the stager runs.
		: > "$STAGER_LOG"

		{
			echo "----- Begin live stager log -----"
		} >> "$LOG"

		# BusyBox usually supports tail -f. This lets the web/status reader see
		# progress even though the stager redirects its own stdout/stderr.
		tail -f "$STAGER_LOG" >> "$LOG" 2>&1 &
		TAIL_PID="$!"

		# Run stager. Its internal LOG variable is forced to STAGER_LOG.
		# Preserve caller overrides like NO_REBOOT=1 and INITRAMFS=/tmp/foo.bin.
		LOG="$STAGER_LOG" "$STAGER"
		RC="$?"

		stop_tail

		{
			echo "----- End live stager log -----"
			echo "Stager exited with code: $RC"
			echo "Staging ends; router should continue in initramfs with autoscripting."
			echo "Give it a minute or two after reboot."
			echo "Finished: $(date)"
			echo "======================================="
			echo ""
		} >> "$LOG" 2>&1

		rm -f "$RUNNING"
	fi

	sleep 1
done
