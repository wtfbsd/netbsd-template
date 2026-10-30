#!/bin/sh
#
# tests/boot-test.sh — boot an image in a VM and wait until it is usable.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# usage: tests/boot-test.sh IMAGE PROFILE [NAME]
#
#   IMAGE    the disk image to boot
#   PROFILE  appliance or desktop
#   NAME     the name of the VM (default: one per run)
#
# The VM is handled through ci/vm.sh only, so the same script works with
# any provider. The test waits for a login prompt on the serial console
# and, for the appliance profile, for sshd to answer on port 22. It exits
# non-zero on a timeout and always destroys the VM.
#
# Knobs (environment):
#   WTFBSD_BOOT_TIMEOUT    seconds to wait for each step (default 600)
#   WTFBSD_BOOT_SSH_PORT   port the sshd probe uses (default 22)
#   WTFBSD_BOOT_VM_NAME    name of the VM (default: one per run)
#   WTFBSD_VM_NAME         name of the VM, when the boot test is called
#                          without a third argument

set -eu

PROG=$(basename -- "$0")
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
vmsh="$repo/ci/vm.sh"

log() { printf '%s: %s\n' "$PROG" "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	printf 'usage: %s IMAGE PROFILE [NAME]\n' "$PROG" >&2
	exit 2
}

[ $# -ge 2 ] && [ $# -le 3 ] || usage
IMAGE=$1
PROFILE=$2

TIMEOUT=${WTFBSD_BOOT_TIMEOUT:-600}
SSH_PORT=${WTFBSD_BOOT_SSH_PORT:-22}

case $PROFILE in
desktop | appliance) ;;
*) die "PROFILE must be desktop or appliance (got: $PROFILE)" ;;
esac

# the name of the VM: the pipeline gives one, so that the pipeline can
# destroy the VM again when the build fails
if [ $# -eq 3 ]; then
	VM_NAME=$3
elif [ -n "${WTFBSD_BOOT_VM_NAME:-}" ]; then
	VM_NAME=$WTFBSD_BOOT_VM_NAME
elif [ -n "${WTFBSD_VM_NAME:-}" ]; then
	VM_NAME=$WTFBSD_VM_NAME
else
	VM_NAME="boot-$PROFILE-$$"
fi
[ -n "$VM_NAME" ] || die 'the VM name must not be empty'

[ -f "$IMAGE" ] || die "no such image: $IMAGE"
[ -f "$vmsh" ] || die "no such VM front end: $vmsh"

# a VM that cannot be destroyed is reported: it stays behind on the host
cleanup() {
	rc_destroy=0
	sh "$vmsh" destroy "$VM_NAME" > /dev/null || rc_destroy=$?
	if [ "$rc_destroy" -ne 0 ]; then
		printf '%s: the VM %s could not be destroyed (exit %s)\n' \
			"$PROG" "$VM_NAME" "$rc_destroy" >&2
	fi
	return 0
}
trap cleanup EXIT
trap 'cleanup; exit 1' HUP INT TERM

log "booting $IMAGE as $VM_NAME (profile $PROFILE)"
sh "$vmsh" create "$VM_NAME" "$IMAGE" > /dev/null

LOG=$(sh "$vmsh" console "$VM_NAME")
[ -n "$LOG" ] || die 'the provider printed no serial console log path'

log "waiting up to ${TIMEOUT}s for a login prompt on the serial console"
deadline=$(( $(date +%s) + TIMEOUT ))
seen=0
while [ "$(date +%s)" -lt "$deadline" ]; do
	if [ -f "$LOG" ] && grep -q 'login:' "$LOG" 2> /dev/null; then
		seen=1
		break
	fi
	sleep 2
done
[ "$seen" -eq 1 ] || die "timed out after ${TIMEOUT}s waiting for 'login:' on the serial console"

if [ "$PROFILE" = appliance ]; then
	ADDR=$(sh "$vmsh" addr "$VM_NAME")
	[ -n "$ADDR" ] || die 'the provider printed no guest address'
	log "waiting up to ${TIMEOUT}s for sshd on $ADDR port $SSH_PORT"
	deadline=$(( $(date +%s) + TIMEOUT ))
	up=0
	while [ "$(date +%s)" -lt "$deadline" ]; do
		# the connect is bounded, so a host that drops the packets
		# cannot hold the probe open
		if nc -z -w 2 "$ADDR" "$SSH_PORT" 2> /dev/null; then
			up=1
			break
		fi
		sleep 2
	done
	[ "$up" -eq 1 ] || die "timed out after ${TIMEOUT}s waiting for sshd on $ADDR port $SSH_PORT"
fi

log "boot test passed: $IMAGE ($PROFILE)"
exit 0
