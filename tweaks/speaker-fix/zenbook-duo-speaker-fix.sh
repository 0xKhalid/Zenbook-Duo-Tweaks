#!/bin/bash
set -euo pipefail

#================================================================
#  Zenbook Duo UX8407AA — Speaker Fix
#  Enables the ALSA 'Speaker Switch' on the sof-soundwire card.
#  The UCM profile does not set this control, so it defaults to
#  OFF on every boot, leaving the speakers silent.
#================================================================

CARD="0"
CONTROL_NAME="Speaker Switch"
MAX_WAIT=30

# Wait for the ALSA control to become available (max 30 seconds)
for i in $(seq 1 $MAX_WAIT); do
	if amixer -c "$CARD" cget name="$CONTROL_NAME" &>/dev/null; then
		amixer -c "$CARD" cset name="$CONTROL_NAME" on >/dev/null 2>&1
		exit 0
	fi
	sleep 1
done

echo "zenbook-duo-speaker-fix: timed out waiting for '$CONTROL_NAME' on card $CARD" >&2
exit 1
