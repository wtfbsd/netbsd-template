#!/bin/sh
# tests/fixtures/fake-provider.sh — a ci/vm.sh provider for the tests.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# It implements the provider contract of ci/vm.sh:
#
#   create NAME IMAGE   publish a canned serial log for the VM
#   console NAME        print the path of the serial log
#   addr NAME           print the guest address
#   destroy NAME        stop the fake VM and its listener
#
# The serial log it publishes is a real console transcript (the fixture in
# tests/fixtures/serial-login.log); the "no login prompt" case is derived
# from that same file by cutting it before the prompt.
#
# Knobs (environment):
#   WTFBSD_FAKE_STATE       file the provider appends its calls to
#   WTFBSD_FAKE_LOG         serial log file the VM "writes"
#   WTFBSD_FAKE_SOURCE_LOG  canned serial log to publish (may be empty)
#   WTFBSD_FAKE_ADDR        address printed by the addr subcommand
#   WTFBSD_FAKE_SSH_PORT    port the fake guest listens on (optional)
#   WTFBSD_FAKE_DESTROY_FAIL set to 1 to make the destroy subcommand fail

set -eu

STATE=${WTFBSD_FAKE_STATE:-/tmp/fake-provider.state}
LOG=${WTFBSD_FAKE_LOG:-/tmp/fake-provider.serial}
ADDR=${WTFBSD_FAKE_ADDR:-127.0.0.1}

cmd=${1:-}
[ -n "$cmd" ] || {
	printf 'fake-provider: missing subcommand\n' >&2
	exit 2
}
shift

# a VM name is one short word: a newline in it would split a command
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

case $cmd in
create | console | addr | destroy) ;;
*)
	printf 'fake-provider: unknown subcommand: %s\n' "$cmd" >&2
	exit 2
	;;
esac

_name=${1:-}
[ -n "$_name" ] || {
	printf 'fake-provider: %s needs a VM name\n' "$cmd" >&2
	exit 2
}
valid_name "$_name" || {
	printf 'fake-provider: invalid VM name: %s\n' "$_name" >&2
	exit 2
}

printf '%s %s\n' "$cmd" "$*" >> "$STATE"

listener_pid() {
	printf '%s.listener.pid\n' "$LOG"
}

stop_listener() {
	_pidfile=$(listener_pid)
	if [ -f "$_pidfile" ]; then
		_kill=$(cat "$_pidfile" 2>/dev/null || true)
		if [ -n "$_kill" ]; then
			kill "$_kill" 2>/dev/null || true
		fi
		rm -f "$_pidfile"
	fi
}

case $cmd in
create)
	if [ -n "${WTFBSD_FAKE_SOURCE_LOG:-}" ] && [ -f "$WTFBSD_FAKE_SOURCE_LOG" ]; then
		cp "$WTFBSD_FAKE_SOURCE_LOG" "$LOG"
	else
		: > "$LOG"
	fi
	# the fake guest answers on the ssh port, like the appliance image
	if [ -n "${WTFBSD_FAKE_SSH_PORT:-}" ] && command -v nc > /dev/null 2>&1; then
		(
			while :; do
				nc -l 127.0.0.1 "$WTFBSD_FAKE_SSH_PORT" < /dev/null > /dev/null 2>&1 || true
				sleep 1
			done
		) &
		printf '%s\n' "$!" > "$(listener_pid)"
	fi
	;;
console)
	printf '%s\n' "$LOG"
	;;
addr)
	printf '%s\n' "$ADDR"
	;;
destroy)
	stop_listener
	if [ -n "${WTFBSD_FAKE_DESTROY_FAIL:-}" ]; then
		printf 'fake-provider: the VM %s cannot be destroyed\n' "$_name" >&2
		exit 1
	fi
	;;
*)
	printf 'fake-provider: unknown subcommand: %s\n' "$cmd" >&2
	exit 2
	;;
esac

exit 0
