#!/bin/sh
#
# ci/vm.sh — the one VM front end of this template.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Every VM operation in the CI goes through this script, so a site can
# swap the hypervisor without touching the pipeline:
#
#   ci/vm.sh create NAME IMAGE   boot IMAGE as a VM called NAME
#   ci/vm.sh console NAME        print the path of the serial console log
#   ci/vm.sh addr NAME           print the address of the guest
#   ci/vm.sh destroy NAME        stop the VM and remove its runtime state
#
# The provider is named by WTFBSD_VM_PROVIDER. The provider script is
# $WTFBSD_VM_PROVIDER_PATH when that is set (a file outside this
# repository, so a site can plug in its own), otherwise
# ci/providers/<provider>.sh from this repository. An unknown provider, a
# missing provider and a missing provider script all fail closed.
#
# The provider script receives the same subcommand and the same
# arguments, and must exit non-zero on failure.

set -eu

PROG=$(basename -- "$0")
repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

log() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	log "usage: $PROG create NAME IMAGE | console NAME | addr NAME | destroy NAME" >&2
	exit 2
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

[ $# -ge 1 ] || usage
cmd=$1
shift

case $cmd in
create | console | addr | destroy) ;;
*) die "unknown subcommand: $cmd" ;;
esac

# the name is checked here, before the provider is called: a provider
# that is given a name with a newline in it would run it as a command
case $cmd in
create)
	[ $# -ge 2 ] || usage
	valid_name "$1" || die "invalid VM name: $1"
	;;
console | addr | destroy)
	[ $# -ge 1 ] || usage
	valid_name "$1" || die "invalid VM name: $1"
	;;
esac

provider=${WTFBSD_VM_PROVIDER:-}
[ -n "$provider" ] || die 'WTFBSD_VM_PROVIDER is not set: name the provider to use (the shipped one is "bhyve")'
case $provider in
*[!A-Za-z0-9_-]*) die "invalid provider name: $provider" ;;
esac

if [ -n "${WTFBSD_VM_PROVIDER_PATH:-}" ]; then
	script=$WTFBSD_VM_PROVIDER_PATH
	[ -f "$script" ] || die "WTFBSD_VM_PROVIDER_PATH does not exist: $script"
else
	script="$repo/ci/providers/$provider.sh"
	if [ ! -f "$script" ]; then
		available=$(cd "$repo/ci/providers" 2>/dev/null && ls | sed 's/\.sh$//' | tr '\n' ' ')
		die "unknown VM provider: $provider (no ci/providers/$provider.sh; available: ${available:-none})"
	fi
fi

if [ -x "$script" ]; then
	exec "$script" "$cmd" "$@"
else
	exec sh "$script" "$cmd" "$@"
fi
