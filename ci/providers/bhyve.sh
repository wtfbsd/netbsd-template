#!/bin/sh
#
# ci/providers/bhyve.sh — the reference VM provider for ci/vm.sh.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# It boots a guest with stock FreeBSD bhyve(8) and logs the serial
# console through a nmdm(4) device, so the boot test can read the console
# transcript from a file.
#
# Contract (called by ci/vm.sh, never by hand):
#   create NAME IMAGE   boot IMAGE as a VM called NAME
#   console NAME        print the path of the serial console log
#   addr NAME           print the address of the guest
#   destroy NAME        stop the VM and remove its runtime state
#   unit NAME           print the null-modem pair and the tap of a VM
#                       (a computation, it needs no privilege)
#
# It needs root (bhyve(8), nmdm(4), tap(4)) on a FreeBSD host, and these
# tools on the host: bhyve, bhyvectl, ifconfig, arp.
#
# The serial console is a null-modem pair: /dev/nmdmNA is the side
# bhyve(8) writes to, /dev/nmdmNB is the side the reader reads from.
# The reader puts its end of the device in raw mode without echo: the
# device opens in canonical mode with echo, the prompt of getty has no
# newline, so a canonical read never returns it, and echo would feed the
# guest output back to the guest as input.
#
# Knobs (environment):
#   WTFBSD_BHYVE_CPUS      vCPUs (default 2)
#   WTFBSD_BHYVE_MEM       memory (default 2G)
#   WTFBSD_BHYVE_DISK      size of a disk created by the provider (default 16G)
#   WTFBSD_BHYVE_FIRMWARE  UEFI firmware; an empty value means no boot ROM
#                          (default /usr/local/share/uefi-firmware/BHYVE_UEFI.fd)
#   WTFBSD_BHYVE_NMDM      the null-modem pair of the serial console
#                          (default: the unit of the executor and of the
#                          slot of the VM)
#   WTFBSD_BHYVE_TAP       tap device to attach (default: the tap of that unit)
#   WTFBSD_VM_SLOT         the slot of the VM in its job: the build VM has
#                          the slot 0 and the boot-test VMs the slot 1, so
#                          that two VMs of one job never share a device
#   WTFBSD_BHYVE_BRIDGE    bridge the tap is attached to; without it the
#                          guest has no network and "addr" finds no address
#   WTFBSD_BHYVE_STATE     directory for the runtime state of the VMs
#                          (default /var/tmp/wtfbsd-vm)
#   WTFBSD_BHYVE_CONSOLE   directory for the pid files of the console
#                          readers (default: the state directory)
#   WTFBSD_BHYVE_DIRECT    set to 1 to boot the image in place instead of
#                          copying it (the artifact is then modified)

set -eu

PROG=$(basename -- "$0")

CPUS=${WTFBSD_BHYVE_CPUS:-2}
MEM=${WTFBSD_BHYVE_MEM:-2G}
DISK=${WTFBSD_BHYVE_DISK:-16G}
FIRMWARE=${WTFBSD_BHYVE_FIRMWARE-/usr/local/share/uefi-firmware/BHYVE_UEFI.fd}
STATE=${WTFBSD_BHYVE_STATE:-/var/tmp/wtfbsd-vm}
CONSOLE_DIR=${WTFBSD_BHYVE_CONSOLE:-$STATE}
BRIDGE=${WTFBSD_BHYVE_BRIDGE:-}

# Two CI jobs on one host must not share a null-modem pair or a tap, so
# the unit of both follows the executor when there is one.
#
# The VMs of one job run on the same executor, so the unit follows the
# slot of the VM as well: the build VM has the slot 0 and the boot-test
# VMs the slot 1 (the variable WTFBSD_VM_SLOT). Two VMs of one job never
# share a device, so the boot-test VM never takes the device of the
# build VM of the same job.
#
# The unit is not wrapped: nmdm(4) and tap(4) take any unit number, and
# a unit that is taken by a modulo is a device that two jobs share.
executor=${EXECUTOR_NUMBER:-}
case $executor in
'' | *[!0-9]*) executor=0 ;;
esac
slot=${WTFBSD_VM_SLOT:-0}
case $slot in
'' | *[!0-9]*) slot=0 ;;
esac
unit=$(( executor * 2 + slot ))

NMDM=${WTFBSD_BHYVE_NMDM:-/dev/nmdm$unit}
case $NMDM in
*[AB]) NMDM=${NMDM%[AB]} ;;
esac
NMDM_A="$NMDM"A
NMDM_B="$NMDM"B
TAP=${WTFBSD_BHYVE_TAP:-tap$unit}

log() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	log "usage: $PROG create NAME IMAGE | console NAME | addr NAME | destroy NAME" >&2
	exit 2
}

# rm -rf only below the state directory, never the state directory itself
rmrf() {
	[ -n "${1:-}" ] || die 'rmrf: empty path'
	[ -n "${2:-}" ] || die 'rmrf: empty guard root'
	[ "$1" != "$2" ] || die "rmrf: refusing guard root itself: $1"
	case $1 in "$2"/*) ;; *) die "rmrf: refusing path outside $2: $1" ;; esac
	[ -d "$1" ] || return 0
	rm -rf -- "$1"
}

# a VM name is one short word: it names a device, a file and an argument,
# and a newline in it would split a command in two
valid_name() { # valid_name <name>
	_v=${1:-}
	[ -n "$_v" ] || return 1
	[ "${#_v}" -le 64 ] || return 1
	case $_v in
	*[!A-Za-z0-9_.-]*) return 1 ;;
	esac
	case $_v in
	-* | .*) return 1 ;;
	esac
	return 0
}

# a stable MAC per VM name, so that "addr" can find the guest again
mac_of() {
	_crc=$(printf '%s' "$1" | cksum | awk '{print $1}')
	printf '52:54:00:%02x:%02x:%02x\n' \
		$(( (_crc / 65536) % 256 )) $(( (_crc / 256) % 256 )) $(( _crc % 256 ))
}

vmdir() {
	printf '%s/%s\n' "$STATE" "$1"
}

# a reader of an earlier run still holds the null-modem open, and the
# guest then writes nothing: it is killed before a new one is started
kill_reader() { # kill_reader <name>
	_pidfile="$CONSOLE_DIR/$1.reader.pid"
	[ -f "$_pidfile" ] || return 0
	_pid=$(cat "$_pidfile" 2> /dev/null || true)
	if [ -n "$_pid" ]; then
		kill "$_pid" 2> /dev/null || true
	fi
	rm -f "$_pidfile"
}

cmd=${1:-}
[ -n "$cmd" ] || usage
shift

# the provider runs with the privileges of the agent, and bhyve(8), the
# null-modem and the tap need root. The "unit" subcommand is a
# computation that touches nothing, so it needs no privilege.
if [ "$cmd" != unit ]; then
	[ "$(id -u)" -eq 0 ] || die 'the bhyve provider needs root (bhyve(8), nmdm(4) and tap(4))'
fi

case $cmd in
unit)
	# the null-modem pair and the tap of a VM: the devices it would
	# use, so that the assignment can be checked without a FreeBSD host
	printf 'nmdm=%s\ntap=%s\n' "$NMDM_A" "$TAP"
	;;
create)
	name=${1:-}
	image=${2:-}
	[ -n "$name" ] && [ -n "$image" ] || usage
	valid_name "$name" || die "invalid VM name: $name"
	[ -f "$image" ] || die "no such image: $image"
	# bhyve parses its options at commas, so a path with a comma in it
	# would be read as two options
	case $image in
	*,*) die "the image path must not hold a comma: $image" ;;
	esac
	dir=$(vmdir "$name")
	mkdir -p "$dir"
	mac=$(mac_of "$name")
	printf '%s\n' "$mac" > "$dir/mac"

	# the disk: a copy of the artifact, so the artifact is never touched
	if [ "${WTFBSD_BHYVE_DIRECT:-0}" = 1 ]; then
		disk=$image
	else
		disk="$dir/disk.img"
		cp "$image" "$disk"
	fi

	# the serial console: the null-modem pair of the unit
	kldload nmdm > /dev/null 2>&1 || true
	_i=0
	while [ ! -c "$NMDM_A" ] && [ "$_i" -lt 20 ]; do
		sleep 1
		_i=$((_i + 1))
	done
	[ -c "$NMDM_A" ] || die "no $NMDM_A: the nmdm module did not provide a serial device"
	kill_reader "$name"
	: > "$dir/console.log"
	# the reader: stty and cat share the same open file, so the device is
	# in raw mode without echo while it is read
	( stty raw -echo; exec cat ) < "$NMDM_B" > "$dir/console.log" &
	mkdir -p "$CONSOLE_DIR"
	printf '%s\n' "$!" > "$CONSOLE_DIR/$name.reader.pid"

	# the tap of the guest, attached to the bridge of the host
	if [ -n "$TAP" ]; then
		command -v ifconfig > /dev/null 2>&1 || die 'ifconfig is required to create the tap'
		# bhyve(8) opens the tap whether or not it is bridged: it is
		# created in both cases, and only attached when there is a bridge
		ifconfig "$TAP" > /dev/null 2>&1 || ifconfig "$TAP" create
		ifconfig "$TAP" up
		if [ -n "$BRIDGE" ]; then
			ifconfig "$BRIDGE" > /dev/null 2>&1 || die "no such bridge: $BRIDGE"
			ifconfig "$BRIDGE" addm "$TAP"
			ifconfig "$BRIDGE" up
		fi
	fi

	# the guest
	set -- -c "$CPUS" -m "$MEM" -A -H -P
	if [ -n "$FIRMWARE" ]; then
		[ -f "$FIRMWARE" ] || die "no UEFI firmware at $FIRMWARE (the edk2-bhyve package provides it)"
		set -- "$@" -l bootrom,"$FIRMWARE"
	fi
	set -- "$@" -s 0:0,hostbridge
	set -- "$@" -s 1:0,virtio-blk,"$disk"
	if [ -n "$TAP" ]; then
		set -- "$@" -s 2:0,virtio-net,"$TAP","$mac"
	fi
	# the serial port of the guest hangs on the LPC device
	set -- "$@" -s 31,lpc
	set -- "$@" -l com1,"$NMDM_A"
	set -- "$@" "$name"
	bhyve "$@" > "$dir/bhyve.log" 2>&1 &
	printf '%s\n' "$!" > "$dir/bhyve.pid"
	log "$PROG: started $name (console $dir/console.log, mac $mac)"
	;;
console)
	name=${1:-}
	[ -n "$name" ] || usage
	valid_name "$name" || die "invalid VM name: $name"
	dir=$(vmdir "$name")
	[ -f "$dir/console.log" ] || die "no console log for $name (was it created?)"
	printf '%s\n' "$dir/console.log"
	;;
addr)
	name=${1:-}
	[ -n "$name" ] || usage
	valid_name "$name" || die "invalid VM name: $name"
	dir=$(vmdir "$name")
	[ -f "$dir/mac" ] || die "no runtime state for $name (was it created?)"
	mac=$(cat "$dir/mac")
	ip=$(arp -an 2>/dev/null | grep -i -- "$mac" | head -1 | sed -n 's/.*(\([0-9][0-9.]*\)).*/\1/p')
	if [ -z "$ip" ]; then
		die "no address known yet for $name (mac $mac); the guest has to talk on the network first"
	fi
	printf '%s\n' "$ip"
	;;
destroy)
	name=${1:-}
	[ -n "$name" ] || usage
	valid_name "$name" || die "invalid VM name: $name"
	dir=$(vmdir "$name")
	kill_reader "$name"
	if [ -f "$dir/bhyve.pid" ]; then
		pid=$(cat "$dir/bhyve.pid" 2> /dev/null || true)
		if [ -n "$pid" ]; then
			kill "$pid" 2> /dev/null || true
		fi
	fi
	# a VM that is not there any more is gone already, and the tool that
	# removes it has to be there to remove it
	if [ -e "/dev/vmm/$name" ]; then
		command -v bhyvectl > /dev/null 2>&1 || die "bhyvectl is not installed: $name cannot be destroyed"
		bhyvectl --vm="$name" --kill > /dev/null 2>&1 || true
		bhyvectl --destroy --vm="$name" > /dev/null 2>&1 || die "bhyvectl could not destroy $name"
		log "$PROG: destroyed $name"
	else
		log "$PROG: $name is not running: nothing to destroy"
	fi
	if [ -n "$TAP" ] && [ -n "$BRIDGE" ]; then
		ifconfig "$BRIDGE" deletem "$TAP" > /dev/null 2>&1 || true
	fi
	rmrf "$dir" "$STATE"
	;;
*)
	usage
	;;
esac

exit 0
