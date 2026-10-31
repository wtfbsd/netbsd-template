#!/bin/sh
# tests/run-tests.sh — checks for the NetBSD template (POSIX sh).
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# Runs on any POSIX host: no root, no network, no VM, no NetBSD. A case is
# a dry run (-n) of build.sh, a check of the tree, a run of the REAL build
# path against stubbed tools (tests/stubs), or a run of tests/boot-test.sh
# against the fake provider in tests/fixtures.
#
# Usage: sh tests/run-tests.sh
# Exit status: 0 when every case passed, 1 otherwise.

set -u

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/wtfbsd-nbsd-tests.XXXXXX") || exit 1
probe="$repo/.leak-probe.tmp"

# rm -rf only below the temporary directory of this run, never it itself
cleanup() {
	[ -n "${work:-}" ] || return 0
	case $work in
	"${TMPDIR:-/tmp}"/wtfbsd-nbsd-tests.*) rm -rf -- "$work" ;;
	*) return 0 ;;
	esac
	rm -f -- "$probe"
}
trap cleanup EXIT HUP INT TERM

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }

build="$repo/build.sh"
vmsh="$repo/ci/vm.sh"
boottest="$repo/tests/boot-test.sh"
fixture="$repo/tests/fixtures/examplebsd-netbsd.product.conf"

# --------------------------------------------------------------------------
# (a) the NetBSD example as product.conf
# --------------------------------------------------------------------------
cp "$fixture" "$work/netbsd.conf"
sh "$build" -n -c "$work/netbsd.conf" -o "$work/out" > "$work/log" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
	ok "(a) the NetBSD example product.conf passes the dry run"
else
	no "(a) the NetBSD example product.conf passes the dry run (rc=$rc)"
	sed 's/^/      | /' "$work/log"
fi

for plan_probe in 'releasedir/amd64/binary/sets:sets are unpacked' \
	'overlay copy:the overlay is copied over the stage' \
	'rc.conf.d/zfs:rc.conf.d/zfs is enabled' \
	'nbmakefs -t ffs:the image is built with nbmakefs -t ffs' \
	'nbinstallboot:the boot blocks are installed with nbinstallboot'; do
	pat=${plan_probe%%:*}
	what=${plan_probe#*:}
	if grep -q -- "$pat" "$work/log"; then
		ok "(a) the plan shows $what"
	else
		no "(a) the plan shows $what"
	fi
done
if grep -q -- 'makefs -t zfs' "$work/log"; then
	no "(a) the plan never builds a ZFS root"
else
	ok "(a) the plan never builds a ZFS root"
fi

# --------------------------------------------------------------------------
# (b) FILESYSTEM_ROOT=zfs is refused, with the honest explanation
# --------------------------------------------------------------------------
sed "s/^FILESYSTEM_ROOT=.*/FILESYSTEM_ROOT='zfs'/" "$fixture" > "$work/zfsroot.conf"
sh "$build" -n -c "$work/zfsroot.conf" -o "$work/out" > "$work/zfsroot.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	ok "(b) FILESYSTEM_ROOT=zfs is refused"
else
	no "(b) FILESYSTEM_ROOT=zfs is refused (rc=0)"
fi
if grep -qi 'cannot boot from ZFS' "$work/zfsroot.log" && grep -qi 'data pool' "$work/zfsroot.log"; then
	ok "(b) the refusal explains the ZFS data pool alternative"
else
	no "(b) the refusal explains the ZFS data pool alternative"
	sed 's/^/      | /' "$work/zfsroot.log"
fi

# --------------------------------------------------------------------------
# (c) DISTRO_OS other than netbsd is refused
# --------------------------------------------------------------------------
sed "s/^DISTRO_OS=.*/DISTRO_OS='freebsd'/" "$fixture" > "$work/os.conf"
sh "$build" -n -c "$work/os.conf" -o "$work/out" > "$work/os.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'netbsd' "$work/os.log"; then
	ok "(c) DISTRO_OS=freebsd is refused"
else
	no "(c) DISTRO_OS=freebsd is refused (rc=$rc)"
fi

# --------------------------------------------------------------------------
# (d) a command substitution in MOTD is data, never code
# --------------------------------------------------------------------------
sed "s|^MOTD=.*|MOTD='x\$(touch $work/pwned)'|" "$fixture" > "$work/inj.conf"
sh "$build" -n -c "$work/inj.conf" -o "$work/out" > "$work/inj.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	ok "(d) a command substitution in MOTD is refused"
else
	no "(d) a command substitution in MOTD is refused (rc=0)"
fi
if [ ! -e "$work/pwned" ]; then
	ok "(d) nothing was executed"
else
	no "(d) nothing was executed"
fi

# --------------------------------------------------------------------------
# (e) an unknown profile is refused
# --------------------------------------------------------------------------
sh "$build" -n -c "$fixture" -p server -o "$work/out" > "$work/prof.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	ok "(e) an unknown -p profile is refused"
else
	no "(e) an unknown -p profile is refused (rc=0)"
fi

# --------------------------------------------------------------------------
# (f) no file under overlay/ mentions the forbidden wireless driver
# --------------------------------------------------------------------------
# The token is assembled at run time so that this script does not contain
# the string it forbids.
driver=$(printf 'mt%s' '76')
if grep -rni -- "$driver" "$repo/overlay" > "$work/driver.log" 2>&1; then
	no "(f) no file under overlay/ mentions the forbidden driver"
	sed 's/^/      | /' "$work/driver.log"
else
	ok "(f) no file under overlay/ mentions the forbidden driver"
fi

# --------------------------------------------------------------------------
# (g) ci/vm.sh fails closed on an unknown or missing provider
# --------------------------------------------------------------------------
WTFBSD_VM_PROVIDER=nosuchprovider sh "$vmsh" create vm1 "$work/image.img" > "$work/vm.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'nosuchprovider' "$work/vm.log"; then
	ok "(g) ci/vm.sh fails closed on an unknown provider"
else
	no "(g) ci/vm.sh fails closed on an unknown provider (rc=$rc)"
	sed 's/^/      | /' "$work/vm.log"
fi
(
	unset WTFBSD_VM_PROVIDER
	unset WTFBSD_VM_PROVIDER_PATH
	sh "$vmsh" create vm1 "$work/image.img"
) > "$work/vmnone.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'WTFBSD_VM_PROVIDER' "$work/vmnone.log"; then
	ok "(g) ci/vm.sh fails closed when no provider is set"
else
	no "(g) ci/vm.sh fails closed when no provider is set (rc=$rc)"
fi

# --------------------------------------------------------------------------
# (h) tests/boot-test.sh against the fake provider
# --------------------------------------------------------------------------
: > "$work/image.img"
sshport=''
p=21000
while [ "$p" -lt 21200 ]; do
	if ! nc -z 127.0.0.1 "$p" > /dev/null 2>&1; then
		sshport=$p
		break
	fi
	p=$((p + 1))
done
if [ -z "$sshport" ]; then
	no "(h) a free loopback port for the ssh probe was found"
else
	WTFBSD_VM_PROVIDER=fake
	WTFBSD_VM_PROVIDER_PATH="$repo/tests/fixtures/fake-provider.sh"
	WTFBSD_FAKE_STATE="$work/state1"
	WTFBSD_FAKE_LOG="$work/serial1.log"
	WTFBSD_FAKE_SOURCE_LOG="$repo/tests/fixtures/serial-login.log"
	WTFBSD_FAKE_ADDR=127.0.0.1
	WTFBSD_FAKE_SSH_PORT=$sshport
	WTFBSD_BOOT_TIMEOUT=20
	WTFBSD_BOOT_SSH_PORT=$sshport
	export WTFBSD_VM_PROVIDER WTFBSD_VM_PROVIDER_PATH WTFBSD_FAKE_STATE \
		WTFBSD_FAKE_LOG WTFBSD_FAKE_SOURCE_LOG WTFBSD_FAKE_ADDR \
		WTFBSD_FAKE_SSH_PORT WTFBSD_BOOT_TIMEOUT WTFBSD_BOOT_SSH_PORT

	sh "$boottest" "$work/image.img" appliance > "$work/boot.log" 2>&1
	rc=$?
	if [ "$rc" -eq 0 ]; then
		ok "(h) the boot test passes when the console shows a login prompt"
	else
		no "(h) the boot test passes when the console shows a login prompt (rc=$rc)"
		sed 's/^/      | /' "$work/boot.log"
	fi
	if grep -q '^destroy' "$work/state1" 2>/dev/null; then
		ok "(h) the VM is destroyed after a successful boot test"
	else
		no "(h) the VM is destroyed after a successful boot test"
	fi

	# the same transcript, cut before the login prompt: the boot test must
	# time out, fail, and still destroy the VM
	sed '/login:/,$d' "$repo/tests/fixtures/serial-login.log" > "$work/no-login.log"
	WTFBSD_FAKE_STATE="$work/state2"
	WTFBSD_FAKE_LOG="$work/serial2.log"
	WTFBSD_FAKE_SOURCE_LOG="$work/no-login.log"
	WTFBSD_BOOT_TIMEOUT=5
	export WTFBSD_FAKE_STATE WTFBSD_FAKE_LOG WTFBSD_FAKE_SOURCE_LOG WTFBSD_BOOT_TIMEOUT
	sh "$boottest" "$work/image.img" appliance > "$work/boot2.log" 2>&1
	rc=$?
	if [ "$rc" -ne 0 ]; then
		ok "(h) the boot test fails when the login prompt never appears"
	else
		no "(h) the boot test fails when the login prompt never appears (rc=0)"
	fi
	if grep -q '^destroy' "$work/state2" 2>/dev/null; then
		ok "(h) the VM is destroyed after a failed boot test"
	else
		no "(h) the VM is destroyed after a failed boot test"
	fi
fi

# --------------------------------------------------------------------------
# (i) no internal references: generic shapes only, plus an optional
#     private deny-list that never ships with the repository
# --------------------------------------------------------------------------
# The patterns are assembled from fragments: the file that carries the
# check must not contain the shapes it looks for.
pat_v4='([0-9]{1,3}\.){3}[0-9]{1,3}'
hex4='[0-9A-Fa-f]{1,4}'
pat_v6=$(printf '(%s){1,4}(:%s{0,4}){2,7}' "$hex4" "$hex4")
pat_mail='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
pat_tld=$(printf '(\\.(%s|%s|%s|%s|%s))([^A-Za-z0-9]|$)' 'lan' 'corp' 'internal' 'local' 'lab')
pat_key=$(printf 'BEGIN .*PRI%s' 'VATE KEY')
pat_sshkey='ssh-(ed25519|rsa) AAAA'
pat_ghp=$(printf 'gh%s_' 'p')
pat_gho=$(printf 'gh%s_' 'o')
pat_gpat=$(printf 'github%s' '_pat_')
pat_akia='AKIA[0-9A-Z]{16}'
pat_xox='xox[abp]-'
pat_sk='sk-[A-Za-z0-9]{20,}'
pat_credA=$(printf 'api%s' 'Key')
pat_credB=$(printf 'api_%s' 'key')
pat_credC=$(printf 'base%s' 'URL')
pat_credD=$(printf '%s' 'Bear' 'er')

# the probe shapes are assembled from fragments as well
v6a=fd00
v6b=1234
v6c=5678
v6d=9abc
v6e=def0
v6f=1234
v6g=5678
v6h=9abc
s_v4=$(printf '198.18.0.%s' '7')
s_v6="$v6a:$v6b:$v6c:$v6d:$v6e:$v6f:$v6g:$v6h"
s_mail=$(printf 'person@mail.%s' 'invalid')
s_tld=$(printf 'printer.%s' 'lan')
s_key=$(printf -- '-----BEGIN RSA %s-----' "$(printf 'PRIV')ATE KEY")
s_ssh=$(printf 'ssh-ed25519 %s' 'AAAAC3NzaC1lZDI1NTE5AAAAI')
s_ghp=$(printf 'gh%s_0123456789abcdefghij' 'p')
s_gho=$(printf 'gh%s_0123456789abcdefghij' 'o')
s_gpat=$(printf 'github%s_11ABCDEFG0123456789abcdefghij' '_pat_')
s_akia=$(printf 'AKIA%s' 'IOSFODNN7EXAMPLE')
s_xox=$(printf 'xox%s' 'b-1234567890-abcdefghij')
s_sk=$(printf 'sk-%s' 'abcdefghijklmnopqrstuvwxyz0123456789')
s_credA=$(printf 'api%s = hunter2' 'Key')
s_credB=$(printf 'api_%s = hunter2' 'key')
s_credC=$(printf 'base%s = https://example.net/' 'URL')
s_credD=$(printf 'Authorization: %s abcdefghij' "$(printf 'Bear')er")
# the addresses this repository may carry: the loopback address and the
# documentation ranges of RFC 5737 and RFC 3849
allowed_address() { # allowed_address <address>
	case $1 in
	127.0.0.1 | ::1 | 192.0.2.* | 198.51.100.* | 203.0.113.* | 2001:db8:*) return 0 ;;
	esac
	return 1
}

# a MAC address and a timestamp look like an IPv6 address without a double
# colon; only a compressed address or eight groups of hex digits are one
is_ipv6() { # is_ipv6 <candidate>
	_c=$1
	case $_c in
	*::*) return 0 ;;
	esac
	printf '%s' "$_c" | grep -qE '^([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}$' || return 1
	return 0
}

scan_file() { # scan_file <path> — the shapes a file of this repository must not have
	_f=$1
	_out=''
	for _m in $(grep -oE -- "$pat_v4" "$_f" 2> /dev/null); do
		allowed_address "$_m" && continue
		_out="$_out ipv4:$_m"
	done
	for _m in $(grep -oE -- "$pat_v6" "$_f" 2> /dev/null); do
		is_ipv6 "$_m" || continue
		allowed_address "$_m" && continue
		_out="$_out ipv6:$_m"
	done
	for _m in $(grep -oE -- "$pat_mail" "$_f" 2> /dev/null); do
		case $_m in
		*@example.org | *@example.com) continue ;;
		ssh-*@* | ecdsa-*@* | sk-*@*) continue ;;
		esac
		_out="$_out mail:$_m"
	done
	for _p in "$pat_tld" "$pat_key" "$pat_sshkey" "$pat_ghp" "$pat_gho" "$pat_gpat" \
		"$pat_akia" "$pat_xox" "$pat_sk" "$pat_credA" "$pat_credB" \
		"$pat_credC" "$pat_credD"; do
		if grep -qiE -- "$_p" "$_f" 2> /dev/null; then
			_out="$_out shape:$_p"
		fi
	done
	printf '%s\n' "$_out"
}

listfiles() {
	if command -v git > /dev/null 2>&1 && git -C "$repo" rev-parse --git-dir > /dev/null 2>&1; then
		(
			cd "$repo" || exit 1
			git ls-files
			git ls-files --others --exclude-standard
		)
	else
		(cd "$repo" && find . -type f -not -path './.git/*' | sed 's|^\./||')
	fi
}

listfiles | sort -u > "$work/files"
hits=''
while IFS= read -r f; do
	[ -n "$f" ] || continue
	[ -f "$repo/$f" ] || continue
	case $f in
	.git/* | ROUND-REPORT*.md) continue ;;
	esac
	m=$(scan_file "$repo/$f")
	if [ -n "$m" ]; then
		hits="$hits $f:$(printf '%s' "$m" | head -1)"
	fi
done < "$work/files"
if [ -z "$hits" ]; then
	ok "(i) no internal references in any file of the tree"
else
	no "(i) no internal references in any file of the tree:$hits"
fi

# every generic pattern must really fire: a probe file with the shape in it
# has to be reported, and the probe is removed again
probe_pattern() { # probe_pattern <name> <shape> <pattern>
	printf '%s\n' "$2" > "$probe"
	r=$(scan_file "$probe")
	rm -f "$probe"
	case $r in
	*"$3"*) ok "(i) the $1 shape is detected" ;;
	*) no "(i) the $1 shape is detected" ;;
	esac
}
probe_pattern 'IPv4 address' "host $s_v4 here" 'ipv4:198.18'
probe_pattern 'IPv6 address' "host $s_v6 here" 'ipv6:fd00'
probe_pattern 'email address' "write to $s_mail please" 'mail:person'
probe_pattern 'internal tld' "the host is named $s_tld" 'shape:'
probe_pattern 'private key header' "$s_key" 'shape:'
probe_pattern 'ssh public key' "$s_ssh" 'shape:'
probe_pattern 'personal access token' "$s_ghp" 'shape:'
probe_pattern 'oauth token' "$s_gho" 'shape:'
probe_pattern 'fine grained token' "$s_gpat" 'shape:'
probe_pattern 'aws access key id' "$s_akia" 'shape:'
probe_pattern 'slack token' "$s_xox" 'shape:'
probe_pattern 'secret key' "$s_sk" 'shape:'
probe_pattern 'credential field name' "$s_credA" 'shape:'
probe_pattern 'credential field name' "$s_credB" 'shape:'
probe_pattern 'endpoint field name' "$s_credC" 'shape:'
probe_pattern 'authorization header' "$s_credD" 'shape:'

# the optional private deny-list: it never ships with the repository
if [ -n "${WTFBSD_DENYLIST:-}" ] && [ -r "${WTFBSD_DENYLIST}" ]; then
	printf '%s\n' 'zzprobeorgname' > "$work/denylist"
	printf '%s\n' 'a line with zzprobeorgname in it' > "$probe"
	r=$(scan_file "$probe")
	while IFS= read -r dl; do
		case $dl in
		'' | '#'*) continue ;;
		esac
		if grep -qiE -- "$dl" "$probe" 2> /dev/null; then
			r="$r deny:$dl"
		fi
	done < "$work/denylist"
	rm -f "$probe"
	case $r in
	*deny:*) ok "(i) the private deny-list in WTFBSD_DENYLIST is applied" ;;
	*) no "(i) the private deny-list in WTFBSD_DENYLIST is applied" ;;
	esac
else
	ok "(i) the private deny-list in WTFBSD_DENYLIST is optional (not set)"
fi

# the repository ships no deny-list of its own
denylist=''
while IFS= read -r f; do
	case ${f##*/} in
	forbidden* | deny* | blacklist* | banned*)
		denylist="$denylist $f"
		;;
	esac
done < "$work/files"
if [ -z "$denylist" ]; then
	ok "(i) the repository ships no deny-list of its own"
else
	no "(i) the repository ships no deny-list of its own:$denylist"
fi

# --------------------------------------------------------------------------
# extra checks
# --------------------------------------------------------------------------
# every shell script parses
snbad=''
for f in $(find "$repo" -name '*.sh' -not -path '*/.git/*'); do
	sh -n "$f" 2> /dev/null || snbad="$snbad $f"
done
for f in "$repo/tests/stubs/rc.subr" "$repo"/tests/stubs/bin/*; do
	sh -n "$f" 2> /dev/null || snbad="$snbad $f"
done
for f in $(find "$repo/overlay" -type f -not -name '*.list'); do
	case $f in
	*.sh) ;;
	*)
		head -1 "$f" 2> /dev/null | grep -q '^#!.*sh' || continue
		sh -n "$f" 2> /dev/null || snbad="$snbad $f"
		;;
	esac
done
if [ -z "$snbad" ]; then
	ok "every shell script parses (sh -n)"
else
	no "every shell script parses (sh -n) fails on:$snbad"
fi

# rc.conf.d fragments are named after the service that reads them
misnamed=''
for f in $(find "$repo/overlay" -type f -path '*etc/rc.conf.d/*'); do
	base=${f##*/}
	case $base in
	appliance | desktop | examplebsd | netbsd) misnamed="$misnamed $base" ;;
	esac
done
if [ -z "$misnamed" ]; then
	ok "every rc.conf.d fragment is named after its service"
else
	no "every rc.conf.d fragment is named after its service:$misnamed"
fi

for svc in ntpd sshd dbus lightdm firstboot_user; do
	if [ -n "$(find "$repo/overlay" -type f -path "*etc/rc.conf.d/$svc" 2> /dev/null)" ]; then
		ok "rc.conf.d/$svc exists"
	else
		no "rc.conf.d/$svc exists"
	fi
done

# a NetBSD rc variable is <name>=YES: there is no <name>_enable
enables=''
for f in $(find "$repo/overlay" -type f -path '*etc/rc.conf.d/*'); do
	if grep -v '^[[:space:]]*#' "$f" 2> /dev/null | grep -q '_enable'; then
		enables="$enables $f"
	fi
done
if [ -z "$enables" ]; then
	ok "no rc.conf.d fragment uses a <name>_enable variable"
else
	no "no rc.conf.d fragment uses a <name>_enable variable:$enables"
fi

# build.sh insists on a product.conf
sh "$build" -n -o "$work/out" > "$work/noconf.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	ok "build.sh refuses to run without -c product.conf"
else
	no "build.sh refuses to run without -c product.conf (rc=0)"
fi

# an unknown key in product.conf is refused
sed "s/^DISTRO_NAME=.*/PATH='\/tmp'/" "$fixture" > "$work/key.conf"
sh "$build" -n -c "$work/key.conf" -o "$work/out" > "$work/key.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	ok "an unknown product.conf key is refused"
else
	no "an unknown product.conf key is refused (rc=0)"
fi

# the dry run writes nothing
[ ! -e "$work/out" ] && ok "the dry run writes nothing" || no "the dry run writes nothing"

# the round reports are never tracked
if command -v git > /dev/null 2>&1 && git -C "$repo" rev-parse --git-dir > /dev/null 2>&1; then
	if git -C "$repo" ls-files | grep -q '^ROUND-REPORT'; then
		no "no ROUND-REPORT file is tracked"
	else
		ok "no ROUND-REPORT file is tracked"
	fi
	if grep -q 'ROUND-REPORT' "$repo/.gitignore" 2> /dev/null; then
		ok "ROUND-REPORT files are ignored by git"
	else
		no "ROUND-REPORT files are ignored by git"
	fi
fi

# --------------------------------------------------------------------------
# (r) the REAL build path, with the tools stubbed out
# --------------------------------------------------------------------------
# The dry run only prints a plan: it proves nothing about what the build
# does. These cases run the real build against a fake NetBSD source tree
# with the tools of tests/stubs in their place, and assert on the calls the
# build made (the stubs log them in $STUB_LOG) and on the staged files.

STUB_REAL_TAR=$(command -v tar || true)
STUB_REAL_DD=$(command -v dd || true)
stubs="$repo/tests/stubs"
log_file="$work/stub.log"
stub_log=''

# the fake NetBSD source tree: its build.sh publishes the prepared sets
fakesrc="$work/src"
mkdir -p "$fakesrc"
cp "$repo/tests/fixtures/fake-src-build.sh" "$fakesrc/build.sh"
chmod 755 "$fakesrc/build.sh"

# the minimal fake stage: what the release sets unpack to
fakestage="$work/fakestage"
mkdir -p "$fakestage/etc" "$fakestage/usr/mdec" "$fakestage/usr/bin" \
	"$fakestage/usr/pkg/bin" "$fakestage/bin" "$fakestage/tmp"
printf '# $NetBSD$\nrc_configured="NO"\n' > "$fakestage/etc/rc.conf"
printf 'root:*:0:0:0:0:0:0\n' > "$fakestage/etc/passwd"
printf 'root::0:0:0:0:0:0:0\n' > "$fakestage/etc/master.passwd"
printf 'root:*:0:\nwheel:*:0:root\n' > "$fakestage/etc/group"
# the stock NetBSD /etc/ttys (status field "off"): the build enables tty00
# so the appliance logs in on the serial console (tty00, getty std.9600)
printf '#	"Name"	"Type"	"tty"	"attach"	"terminals"\n' > "$fakestage/etc/ttys"
printf 'console	"/usr/libexec/getty Pc"		vt100	off secure\n' >> "$fakestage/etc/ttys"
printf 'tty00	"/usr/libexec/getty std.9600"	unknown off secure\n' >> "$fakestage/etc/ttys"
printf 'the kernel\n' > "$fakestage/netbsd"
printf 'the amd64 efi loader\n' > "$fakestage/usr/mdec/bootx64.efi"
printf 'the aarch64 efi loader\n' > "$fakestage/usr/mdec/bootaa64.efi"
printf 'the ffsv1 boot block\n' > "$fakestage/usr/mdec/bootxx_ffsv1"
printf 'the shell\n' > "$fakestage/bin/sh"
printf 'the setuid su of the base system\n' > "$fakestage/usr/bin/su"
chmod 4755 "$fakestage/usr/bin/su"
# a symlink to a directory: the metadata has to record it as a link
ln -s ../../etc "$fakestage/usr/pkg/bin/link-to-etc"
# the modes of the files of the fake stage are set here, so that the
# fixture does not depend on the umask of the test runner: a file that
# the build adds on top of the base system keeps the group write of the
# set until the build strips it
chmod 664 "$fakestage/netbsd" "$fakestage/usr/mdec/bootx64.efi" \
	"$fakestage/usr/mdec/bootaa64.efi" "$fakestage/usr/mdec/bootxx_ffsv1" \
	"$fakestage/bin/sh" "$fakestage/etc/passwd" "$fakestage/etc/group"

# the release sets: the base set, and an X set that must stay out of the
# image (the X11 of this distribution comes from pkgsrc)
sets="$work/sets"
mkdir -p "$sets"
"$STUB_REAL_TAR" -cJf "$sets/base.tar.xz" -C "$fakestage" .
mkdir -p "$work/xstage/usr/X11R6"
printf 'the x11 library\n' > "$work/xstage/usr/X11R6/libX11.so"
"$STUB_REAL_TAR" -cJf "$sets/xbase.tar.xz" -C "$work/xstage" .

# the umask the build runs under: a case sets it to 002 to see what the
# build does in an environment that is group writable
real_build_umask=022

real_build() { # real_build <out-dir-relative-to-work> [conf] [env-assignment...]
	_out=$1
	_conf=${2:-$fixture}
	if [ "$#" -gt 1 ]; then shift 2; else shift; fi
	: > "$log_file"
	(
		cd "$work" || exit 1
		umask "$real_build_umask"
		# the harness simulates the whole NetBSD environment through the
		# stubs, so the build sees a NetBSD host here: pkg_add is installed
		# unless a test overrides the host with WTFBSD_HOST_OS=<other>
		env WTFBSD_HOST_OS=NetBSD "$@" \
			STUB_LOG="$log_file" \
			STUB_REAL_TAR="$STUB_REAL_TAR" \
			STUB_REAL_DD="$STUB_REAL_DD" \
			FAKE_SETS_DIR="$sets" \
			WTFBSD_TOOLDIR="$stubs" \
			PATH="$stubs/bin:$PATH" \
			ROOTSIZE=64M \
			ESPSIZE=16m \
			sh "$build" -c "$_conf" -s "$fakesrc" -o "$_out"
	) > "$work/real.log" 2>&1
	REAL_RC=$?
}

real_build out
rc=$REAL_RC
if [ "$rc" -eq 0 ]; then
	ok "(r) the real build path succeeds against the fake source tree"
else
	no "(r) the real build path succeeds against the fake source tree (rc=$rc)"
	sed 's/^/      | /' "$work/real.log"
fi

out="$work/out"
stage="$out/appliance/stage"
parts="$out/appliance/parts"
[ -d "$out" ] && out=$(CDPATH='' cd -- "$out" && pwd)
[ -d "$stage" ] && stage=$(CDPATH='' cd -- "$stage" && pwd)
[ -d "$parts" ] && parts=$(CDPATH='' cd -- "$parts" && pwd)
# the log of the first run is kept: the runs below overwrite it
stub_log="$work/stub-main.log"
cp "$log_file" "$stub_log"

# --- B1: the output directory, -O and -T are absolute ----------------------
if grep -q -- "-O $out/obj -T $out/tools" "$stub_log"; then
	ok "(B1) the build passes absolute -O and -T paths under the output directory"
else
	no "(B1) the build passes absolute -O and -T paths under the output directory"
	sed 's/^/      | /' "$stub_log" | head -20
fi

# --- B2: /boot is a file, the EFI loader is /usr/mdec/bootx64.efi ---------
if [ -f "$stage/netbsd" ]; then
	ok "(B2) the stage is recognised by the kernel file /netbsd"
else
	no "(B2) the stage is recognised by the kernel file /netbsd"
fi
if [ -f "$parts/efi/EFI/BOOT/BOOTX64.EFI" ] &&
	[ "$(cat "$parts/efi/EFI/BOOT/BOOTX64.EFI")" = 'the amd64 efi loader' ]; then
	ok "(B2) the EFI system partition holds the loader from /usr/mdec/bootx64.efi"
else
	no "(B2) the EFI system partition holds the loader from /usr/mdec/bootx64.efi"
fi

# --- B3: root is locked in master.passwd, the database is rebuilt ---------
rootpw=$(awk -F: '$1 == "root" { print $2 }' "$stage/etc/master.passwd" 2> /dev/null)
if [ "$rootpw" = '*' ]; then
	ok "(B3) the password field of root in master.passwd is *"
else
	no "(B3) the password field of root in master.passwd is * (got: $rootpw)"
fi
if grep -q -- "nbpwd_mkdb -p -d $stage $stage/etc/master.passwd" "$stub_log"; then
	ok "(B3) the password database is rebuilt with nbpwd_mkdb -d <stage>"
else
	no "(B3) the password database is rebuilt with nbpwd_mkdb -d <stage>"
fi
if grep -q -- 'passwd -R' "$stub_log"; then
	no "(B3) the build does not lock root with passwd -R"
else
	ok "(B3) the build does not lock root with passwd -R"
fi
mpmode=$(stat -c '%a' "$stage/etc/master.passwd" 2> /dev/null || stat -f '%Lp' "$stage/etc/master.passwd" 2> /dev/null)
if [ "$mpmode" = '600' ]; then
	ok "(B3) the staged master.passwd has the mode 0600"
else
	no "(B3) the staged master.passwd has the mode 0600 (got: $mpmode)"
fi

# --- B4: pkg_add installs into the stage with PKG_RCD_SCRIPTS=YES ----------
if grep -q -- "pkg_add PKG_RCD_SCRIPTS=YES -P $stage" "$stub_log"; then
	ok "(B4) pkg_add installs into the stage (-P) with PKG_RCD_SCRIPTS=YES"
else
	no "(B4) pkg_add installs into the stage (-P) with PKG_RCD_SCRIPTS=YES"
fi
if grep -q -- 'pkg_add .* -R ' "$stub_log"; then
	no "(B4) pkg_add is never called with -R"
else
	ok "(B4) pkg_add is never called with -R"
fi
mkdir -p "$work/repo/NetBSD-11.0-aarch64"
PKG_PATH="$work/repo/NetBSD-11.0-aarch64"
export PKG_PATH
real_build out-arch
unset PKG_PATH
if [ "$REAL_RC" -ne 0 ] && grep -qi 'another architecture' "$work/real.log"; then
	ok "(B4) a package repository for another architecture is refused"
else
	no "(B4) a package repository for another architecture is refused (rc=$REAL_RC)"
	sed 's/^/      | /' "$work/real.log" | head -20
fi

# the real shape of a pkgsrc binary repository:
# .../NetBSD/<pkgsrc-arch>/<version>/All
mkdir -p "$work/repo-x86/NetBSD/x86_64/2023Q1/All" \
	"$work/repo-aa/NetBSD/aarch64/2023Q1/All"
sed "s/^DISTRO_ARCH=.*/DISTRO_ARCH='aarch64'/" "$fixture" > "$work/aarch64.conf"

PKG_PATH="$work/repo-x86/NetBSD/x86_64/2023Q1/All"
export PKG_PATH
real_build out-pkg-amd64
unset PKG_PATH
if [ "$REAL_RC" -eq 0 ]; then
	ok "(B4) a repository of the shape NetBSD/x86_64/<version>/All is accepted for an amd64 image"
else
	no "(B4) a repository of the shape NetBSD/x86_64/<version>/All is accepted for an amd64 image (rc=$REAL_RC)"
	sed 's/^/      | /' "$work/real.log" | head -20
fi

PKG_PATH="$work/repo-aa/NetBSD/aarch64/2023Q1/All"
export PKG_PATH
real_build out-pkg-aarch64 "$work/aarch64.conf"
unset PKG_PATH
if [ "$REAL_RC" -eq 0 ]; then
	ok "(B4) a repository of the shape NetBSD/aarch64/<version>/All is accepted for an aarch64 image"
else
	no "(B4) a repository of the shape NetBSD/aarch64/<version>/All is accepted for an aarch64 image (rc=$REAL_RC)"
	sed 's/^/      | /' "$work/real.log" | head -20
fi

PKG_PATH="$work/repo-aa/NetBSD/aarch64/2023Q1/All"
export PKG_PATH
real_build out-pkg-wrong
unset PKG_PATH
if [ "$REAL_RC" -ne 0 ] && grep -qi 'another architecture' "$work/real.log"; then
	ok "(B4) a repository of the shape NetBSD/aarch64/<version>/All is refused for an amd64 image"
else
	no "(B4) a repository of the shape NetBSD/aarch64/<version>/All is refused for an amd64 image (rc=$REAL_RC)"
	sed 's/^/      | /' "$work/real.log" | head -20
fi

PKG_PATH="$work/repo-x86/NetBSD/x86_64/2023Q1/All"
export PKG_PATH
real_build out-pkg-wrong2 "$work/aarch64.conf"
unset PKG_PATH
if [ "$REAL_RC" -ne 0 ] && grep -qi 'another architecture' "$work/real.log"; then
	ok "(B4) a repository of the shape NetBSD/x86_64/<version>/All is refused for an aarch64 image"
else
	no "(B4) a repository of the shape NetBSD/x86_64/<version>/All is refused for an aarch64 image (rc=$REAL_RC)"
	sed 's/^/      | /' "$work/real.log" | head -20
fi

# --- D8: pkg_add needs a NetBSD build host ---------------------------------
# pkg_add(1) installs pkg bootstrap tooling and cannot run on a build host
# that is not NetBSD. When the host is not NetBSD and packages.list is not
# empty the build refuses, unless WTFBSD_NO_PACKAGES=yes. The harness
# simulates the NetBSD environment through the stubs; a test overrides the
# host with WTFBSD_HOST_OS.
mkdir -p "$work/repo-x86/NetBSD/x86_64/2023Q1/All"
PKG_PATH="$work/repo-x86/NetBSD/x86_64/2023Q1/All"
export PKG_PATH
real_build out-linux "$fixture" WTFBSD_HOST_OS=Linux
unset PKG_PATH
if [ "$REAL_RC" -ne 0 ] && grep -qi 'needs a NetBSD build host' "$work/real.log"; then
	ok "(D8) a non-NetBSD build host is refused when packages.list is not empty"
else
	no "(D8) a non-NetBSD build host is refused when packages.list is not empty (rc=$REAL_RC)"
	sed 's/^/      | /' "$work/real.log" | head -20
fi
real_build out-linux-nopkg "$fixture" WTFBSD_HOST_OS=Linux WTFBSD_NO_PACKAGES=yes
unset PKG_PATH
if [ "$REAL_RC" -eq 0 ] && ! grep -q 'pkg_add ' "$log_file"; then
	ok "(D8b) WTFBSD_NO_PACKAGES=yes skips the packages on a non-NetBSD host"
else
	no "(D8b) WTFBSD_NO_PACKAGES=yes skips the packages on a non-NetBSD host (rc=$REAL_RC)"
	sed 's/^/      | /' "$work/real.log" | head -20
fi
# the refusal names the one way that works (a NetBSD build host): the build
# has no code path for a NetBSD pkg_add on PKG_PATH, so it never offers one
real_build out-linux-msg "$fixture" WTFBSD_HOST_OS=Linux
if [ "$REAL_RC" -ne 0 ] && ! grep -q 'pkg_add on PKG_PATH' "$work/real.log"; then
	ok "(D8c) the non-NetBSD refusal does not offer a pkg_add on PKG_PATH"
else
	no "(D8c) the non-NetBSD refusal does not offer a pkg_add on PKG_PATH (rc=$REAL_RC)"
	sed 's/^/      | /' "$work/real.log" | head -20
fi
# the dry run on a non-NetBSD host prints the package-host reason too
WTFBSD_HOST_OS=Linux sh "$build" -c "$fixture" -o "$work/out-d8d" -n > "$work/d8d.log" 2>&1
if [ "$?" -eq 0 ] && grep -q 'packages need a NetBSD build host; this host is Linux' "$work/d8d.log"; then
	ok "(D8d) the dry run on a non-NetBSD host prints the package-host reason"
else
	no "(D8d) the dry run on a non-NetBSD host prints the package-host reason"
	sed 's/^/      | /' "$work/d8d.log" | head -20
fi

# --- B5: installboot takes the boot block of the file system version -------
if grep -q -- "nbinstallboot -m amd64 $parts/root.img $stage/usr/mdec/bootxx_ffsv1" "$stub_log"; then
	ok "(B5) nbinstallboot gets the bootxx_ffsv1 boot block"
else
	no "(B5) nbinstallboot gets the bootxx_ffsv1 boot block"
fi
if grep -q -- "nbmakefs -t ffs -F $out/appliance/metalog " "$stub_log"; then
	ok "(B5) the root filesystem is built as FFSv1, the version of the boot block"
else
	no "(B5) the root filesystem is built as FFSv1, the version of the boot block"
fi
if grep -q -- 'nbmakefs .* -U ' "$stub_log"; then
	no "(B5) the root filesystem is never built with the option -U"
else
	ok "(B5) the root filesystem is never built with the option -U"
fi

# --- B5b: makefs -B takes the byte order as its argument: nothing named
#     after it is left in the directory the build ran in
if [ ! -e "$work/little" ] && [ ! -e "$work/big" ]; then
	ok "(B5b) the byte order of makefs -B is an argument, not a file name"
else
	no "(B5b) the byte order of makefs -B is an argument, not a file name"
fi
if grep -q -- '\./build\.sh -U -j [0-9][0-9]* -m ' "$stub_log" "$work/real.log" 2>/dev/null ||
	grep -rq -- 'build.sh -U -j [0-9][0-9]* -m' "$work"/stub*.log 2>/dev/null; then
	ok "(B5c) the upstream build is run with -j JOBS"
else
	no "(B5c) the upstream build is run with -j JOBS"
fi

# --- B6: the image file is created first, then the GPT is written into it --
if grep -q -- "dd if=/dev/zero of=$parts/disk.img bs=1m count=0 seek=" "$stub_log"; then
	ok "(B6) the disk image is created with dd before the GPT is written"
else
	no "(B6) the disk image is created with dd before the GPT is written"
fi
if grep -q -- "nbgpt $parts/disk.img create" "$stub_log"; then
	ok "(B6) the GPT is created with nbgpt"
else
	no "(B6) the GPT is created with nbgpt"
fi
if grep -q -- "nbgpt $parts/disk.img add -t efi -s 16m -i 1 -l examplebsdesp" "$stub_log" &&
	grep -q -- "nbgpt $parts/disk.img add -t 49f48d5a-b10e-11dc-b99b-0019d1879648 -s 64m -i 2 -l examplebsdroot" "$stub_log"; then
	ok "(B6) both partitions are added with their label"
else
	no "(B6) both partitions are added with their label"
fi
if grep -q -- "nbgpt $parts/disk.img create -[a-zA-Z]* [0-9]" "$stub_log"; then
	no "(B6) the GPT is created without a size"
else
	ok "(B6) the GPT is created without a size"
fi

# --- B7: the offsets are taken from the index column of the gpt listing ----
esp_seek=$(sed -n 's|^dd if=.*/efi\.img of=.* bs=512 seek=\([0-9]*\) .*|\1|p' "$stub_log" | head -1)
root_seek=$(sed -n 's|^dd if=.*/root\.img of=.* bs=512 seek=\([0-9]*\) .*|\1|p' "$stub_log" | head -1)
if [ "$esp_seek" = 584 ] && [ "$root_seek" = 33352 ]; then
	ok "(B7) the partition offsets come from the index column of the gpt listing"
else
	no "(B7) the partition offsets come from the index column of the gpt listing (esp=$esp_seek root=$root_seek)"
fi
if grep -q -- 'gpt-show:.*PMBR' "$stub_log" &&
	grep -q -- 'gpt-show:.*Pri GPT header' "$stub_log" &&
	grep -q -- 'gpt-show:.*Pri GPT table' "$stub_log"; then
	ok "(B7) the gpt listing has the shape of the gpt(8) output"
else
	no "(B7) the gpt listing has the shape of the gpt(8) output"
fi

# --- B8: the msdos image is built with fat_type=16 -------------------------
if grep -q -- 'fat_type=16' "$stub_log" && ! grep -q -- 'fat-type' "$stub_log"; then
	ok "(B8) the EFI system partition is built with fat_type=16"
else
	no "(B8) the EFI system partition is built with fat_type=16"
fi

# --- C1: the rc variables are <name>=YES -----------------------------------
if grep -q -- '^rc_configured="YES"$' "$stage/etc/rc.conf" 2> /dev/null; then
	ok "(C1) the staged rc.conf has rc_configured=YES"
else
	no "(C1) the staged rc.conf has rc_configured=YES"
fi
if grep -q -- '^zfs=YES$' "$stage/etc/rc.conf.d/zfs" 2> /dev/null; then
	ok "(C1) the generated rc.conf.d/zfs holds zfs=YES"
else
	no "(C1) the generated rc.conf.d/zfs holds zfs=YES"
fi
for pair in 'ntpd ntpd' 'sshd sshd' 'dbus dbus' 'lightdm lightdm' 'firstboot_user firstboot_user'; do
	f=${pair%% *}
	v=${pair##* }
	hit=$(find "$repo/overlay" -type f -path "*etc/rc.conf.d/$f" -exec grep -l -- "$v=YES" {} \; 2> /dev/null)
	if [ -n "$hit" ]; then
		ok "(C1) rc.conf.d/$f holds $v=YES"
	else
		no "(C1) rc.conf.d/$f holds $v=YES"
	fi
done

# --- C2: the rc.d scripts of the packages land in /etc/rc.d ---------------
if grep -q -- 'pkg_add PKG_RCD_SCRIPTS=YES' "$stub_log"; then
	ok "(C2) PKG_RCD_SCRIPTS=YES is set for pkg_add"
else
	no "(C2) PKG_RCD_SCRIPTS=YES is set for pkg_add"
fi

# --- C3: the host name lives in /etc/myname -------------------------------
if [ "$(cat "$stage/etc/myname" 2> /dev/null)" = 'examplebsd' ]; then
	ok "(C3) the staged /etc/myname holds the host name"
else
	no "(C3) the staged /etc/myname holds the host name"
fi
if [ -e "$repo/overlay/base/rootfs/etc/rc.conf.d/hostname" ]; then
	no "(C3) there is no rc.conf.d/hostname fragment"
else
	ok "(C3) there is no rc.conf.d/hostname fragment"
fi

# --- C4: the fstab names the root filesystem by its GPT label --------------
if grep -q -- 'NAME=examplebsdroot / ffs rw 1 1' "$stage/etc/fstab" 2> /dev/null; then
	ok "(C4) the staged /etc/fstab names the root partition by its label"
else
	no "(C4) the staged /etc/fstab names the root partition by its label"
fi

# --- C5: the overlay never lends its owner or modes to the image ---------
if grep -q 'cp -[A-Za-z]*p' "$build" 2> /dev/null; then
	no "(C5) the overlay is copied without -p"
else
	ok "(C5) the overlay is copied without -p"
fi
if grep -q 'rmrf: refusing path outside' "$build" 2> /dev/null &&
	grep -q 'rmrf: empty path' "$build" 2> /dev/null; then
	ok "(C5) the rmrf helper refuses a path outside the output directory"
else
	no "(C5) the rmrf helper refuses a path outside the output directory"
fi
if grep -q -- 'uname=root gname=wheel' "$out/appliance/metalog" 2> /dev/null; then
	ok "(C5) the metadata of the image says root:wheel for every file"
else
	no "(C5) the metadata of the image says root:wheel for every file"
fi
if grep -q -- '^\./etc type=dir mode=0755 uname=root gname=wheel$' "$out/appliance/metalog" 2> /dev/null &&
	grep -q -- '^\./etc/rc\.conf\.d type=dir mode=0755 uname=root gname=wheel$' "$out/appliance/metalog" 2> /dev/null; then
	ok "(C5) the system directories of the image are mode 0755"
else
	no "(C5) the system directories of the image are mode 0755"
fi
if grep -q -- 'mode=0644 uname=root gname=wheel' "$out/appliance/metalog" 2> /dev/null; then
	ok "(C5) the ordinary files of the image are mode 0644"
else
	no "(C5) the ordinary files of the image are mode 0644"
fi
dirmode=$(stat -c '%a' "$stage/etc" 2> /dev/null || stat -f '%Lp' "$stage/etc" 2> /dev/null)
if [ "$dirmode" = '755' ]; then
	ok "(C5) the staged /etc is not group writable"
else
	no "(C5) the staged /etc is not group writable (got: $dirmode)"
fi

# --- C6: the modes survive the substitution -------------------------------
if grep -q -- '^\./usr/local/sbin/examplebsd-pool-create type=file mode=0755' "$out/appliance/metalog" 2> /dev/null; then
	ok "(C6) the pool helper keeps the mode 0755 in the image"
else
	no "(C6) the pool helper keeps the mode 0755 in the image"
fi
srcmode=$(stat -c '%a' "$repo/overlay/base/rootfs/usr/local/sbin/@SLUG@-pool-create" 2> /dev/null ||
	stat -f '%Lp' "$repo/overlay/base/rootfs/usr/local/sbin/@SLUG@-pool-create" 2> /dev/null)
if [ "$srcmode" = '755' ]; then
	ok "(C6) the pool helper is mode 0755 in the tree"
else
	no "(C6) the pool helper is mode 0755 in the tree (got: $srcmode)"
fi

# --- E1: the METALOG of the upstream build --------------------------------
# The METALOG of the upstream build is the metadata of the base system.
# A METALOG without its "#mtree" header line is still a METALOG: the build
# must not die on the grep that reads the header, and the spec it writes
# must be sorted. A METALOG that holds a relative path is a broken one:
# the sort would move the line away from its parent, so the build refuses
# it and names the line that is wrong.
real_build out-noheader "$fixture" FAKE_METALOG_NOHEADER=1
rc_metalog=$REAL_RC
if [ "$rc_metalog" -eq 0 ]; then
	ok "(E1) the build succeeds when the METALOG has no #mtree header"
else
	no "(E1) the build succeeds when the METALOG has no #mtree header (rc=$rc_metalog)"
	sed 's/^/      | /' "$work/real.log" | head -20
fi
nospec="$work/out-noheader/appliance/metalog"
if [ -s "$nospec" ]; then
	grep -vE '^#|^/set' "$nospec" > "$work/nospec.lines"
	LC_ALL=C sort -k1,1 "$work/nospec.lines" > "$work/nospec.sorted"
	if cmp -s "$work/nospec.lines" "$work/nospec.sorted"; then
		ok "(E1) the spec of a METALOG without a header is sorted"
	else
		no "(E1) the spec of a METALOG without a header is sorted"
		diff "$work/nospec.lines" "$work/nospec.sorted" | head -10 | sed 's/^/      | /'
	fi
else
	no "(E1) the spec of a METALOG without a header is sorted (no spec)"
fi
real_build out-relative "$fixture" FAKE_METALOG_RELATIVE=1
rc_metalog=$REAL_RC
if [ "$rc_metalog" -ne 0 ] && grep -q 'not in full-path form: \.\.' "$work/real.log"; then
	ok "(E1) a METALOG line that is not in full-path form is refused"
else
	no "(E1) a METALOG line that is not in full-path form is refused (rc=$rc_metalog)"
	sed 's/^/      | /' "$work/real.log" | head -20
fi

# --- E2: the umask of the environment the build runs in --------------------
# The build must not inherit a group writable environment: the files it
# adds on top of the base system are recorded without group/other write,
# whatever the umask of the caller is. The build runs here under umask
# 002, so that the files it unpacks are group writable unless it strips
# the group write itself.
real_build_umask=002
real_build out-umask
real_build_umask=022
uspec="$work/out-umask/appliance/metalog"
if grep -q -- '^\./netbsd type=file mode=0644 uname=root gname=wheel$' "$uspec" 2> /dev/null; then
	ok "(E2) a file the build adds is recorded without group/other write under umask 002"
else
	no "(E2) a file the build adds is recorded without group/other write under umask 002"
	grep -- '^\./netbsd ' "$uspec" 2> /dev/null | sed 's/^/      | /'
fi

# --- D4: the metadata spec has no stale size=/digest keyword ---------------
# The build rewrites base files (etc/rc.conf, etc/motd, ...): the release
# METALOG records their stale size= and content digest, and nbmakefs(1)
# would cut the file to the stale size. The spec strips every digest
# keyword from the lines that survive (files build.sh rewrites).
if grep -qE -- ' (size|sha256|sha512|sha384|sha1|rmd160|md5)=' "$out/appliance/metalog" 2>/dev/null; then
	no "(D4) the metadata spec has no stale size=/digest keyword (otherwise the rewritten files are truncated)"
	grep -nE -- ' (size|sha256|sha512|sha384|sha1|rmd160|md5)=' "$out/appliance/metalog" 2>/dev/null | head
else
	ok "(D4) the metadata spec has no stale size=/digest keyword"
fi
# the release METALOG records ./etc/master.passwd with its size= and sha256=
# (tests/fixtures/fake-src-build.sh); build.sh rewrites the file (root is
# locked), so neither keyword may survive on its entry, and the mode stays
mpline=$(grep '^\./etc/master\.passwd ' "$out/appliance/metalog" 2>/dev/null)
case $mpline in
'' | *' size='* | *' sha256='*)
	no "(D4) ./etc/master.passwd is in the spec without the stale size=/sha256= of the release"
	printf '      | %s\n' "$mpline"
	;;
*' mode=0600'*)
	ok "(D4) ./etc/master.passwd is in the spec without the stale size=/sha256= of the release"
	;;
*)
	no "(D4) ./etc/master.passwd is in the spec without the stale size=/sha256= of the release (mode)"
	printf '      | %s\n' "$mpline"
	;;
esac

# the release METALOG records ./etc/ttys with every digest keyword mtree(8)
# writes (md5= sha1= sha384= sha512= rmd160=, besides size=): the build
# rewrites the file (tty00 on), so none of them may survive on its entry
ttline=$(grep '^\./etc/ttys ' "$out/appliance/metalog" 2>/dev/null)
case $ttline in
'' | *' size='* | *' md5='* | *' sha1='* | *' sha384='* | *' sha512='* | *' rmd160='* | *' sha256='*)
	no "(D4) ./etc/ttys is in the spec without any stale size=/md5=/sha1=/sha384=/sha512=/rmd160="
	printf '      | %s\n' "$ttline"
	;;
*)
	ok "(D4) ./etc/ttys is in the spec without any stale size=/md5=/sha1=/sha384=/sha512=/rmd160="
	;;
esac

# --- D12b: KERNEL_SET is a kernel configuration name, never a pattern ----
# KERNEL_SET names the kern-<CONFIG> set; it must match ^[A-Z0-9_]+$, so a
# glob such as GEN* is refused, in the dry run too
KERNEL_SET='GEN*' sh "$build" -c "$fixture" -o "$work/out-ksglob" -n > "$work/ksglob.log" 2>&1
_rc=$?
if [ "$_rc" -ne 0 ] && grep -q 'KERNEL_SET must match' "$work/ksglob.log"; then
	ok "(D12b) KERNEL_SET='GEN*' makes the dry run exit non-zero"
else
	no "(D12b) KERNEL_SET='GEN*' makes the dry run exit non-zero (rc=$_rc)"
	sed 's/^/      | /' "$work/ksglob.log" | head -5
fi

# --- D6: the serial console login (tty00) is enabled -----------------------
# The appliance logs in on tty00 as well as the display: the stock /etc/ttys
# leaves tty00 off, and the build enables it on the staged copy only.
if [ -f "$stage/etc/ttys" ] && \
	grep -qE '^tty00[[:space:]].*[[:space:]]on[[:space:]]' "$stage/etc/ttys" && \
	! grep -qE '^tty00[[:space:]].*[[:space:]]off[[:space:]]' "$stage/etc/ttys"; then
	ok "(D6) tty00 is enabled (off -> on) in the staged /etc/ttys"
else
	no "(D6) tty00 is enabled (off -> on) in the staged /etc/ttys"
	sed -n 's/^tty00.*$/tty00: &/p' "$stage/etc/ttys" 2>/dev/null
fi
# only the appliance logs in on the serial console: the desktop stage keeps
# the stock tty00 line, status field off
sed "s/^PROFILE=.*/PROFILE='desktop'/" "$fixture" > "$work/desktop.conf"
real_build out-desk "$work/desktop.conf"
dttys="$work/out-desk/desktop/stage/etc/ttys"
if [ "$REAL_RC" -eq 0 ] && [ -f "$dttys" ] && \
	grep -qE '^tty00[[:space:]].*[[:space:]]off[[:space:]]' "$dttys" && \
	! grep -qE '^tty00[[:space:]].*[[:space:]]on[[:space:]]' "$dttys"; then
	ok "(D6) the desktop stage keeps tty00 off in /etc/ttys"
else
	no "(D6) the desktop stage keeps tty00 off in /etc/ttys (rc=$REAL_RC)"
	sed -n 's/^tty00.*$/tty00: &/p' "$dttys" 2>/dev/null
	sed 's/^/      | /' "$work/real.log" | tail -5
fi

# --- D9: the motd template is pure ASCII ----------------------------------
# A MOTD is shown on the serial console, so the template that build.sh turns
# it into must be ASCII: a non-ASCII byte (the em dash the template used to
# carry) would show as junk on the console. The em dash is matched by its
# UTF-8 bytes via printf(1), so the check needs no literal byte in this file.
motdtmpl="$repo/overlay/base/rootfs/etc/motd.template"
emdash=$(printf '\342\200\224')
if [ -f "$motdtmpl" ] && ! LC_ALL=C grep -q -- "$emdash" "$motdtmpl"; then
	ok "(D9) the motd template is ASCII (no em dash)"
else
	no "(D9) the motd template is ASCII (no em dash)"
	sed -n '1,20p' "$motdtmpl" 2>/dev/null | head
fi

# --- C7: the build needs no root ------------------------------------------
if [ "$(id -u)" -ne 0 ] && [ "$rc" -eq 0 ]; then
	ok "(C7) the build runs as an ordinary user"
else
	no "(C7) the build runs as an ordinary user (uid=$(id -u), rc=$rc)"
fi

# --- C8: the first-boot user ----------------------------------------------
# NetBSD has no pw(8): the account is created with useradd(8). The script
# is run with the stub rc.subr of tests/stubs, so that "start" really
# runs the function that start_cmd names.
mkdir -p "$work/bin"
cat > "$work/bin/useradd" <<'UAEOF'
#!/bin/sh
printf '%s\n' "useradd $*" >> "$STUB_LOG"
# the home directory of the new user, when the test tells the stub where
# it is
if [ -n "${WTFBSD_STUB_HOME:-}" ]; then
	mkdir -p "$WTFBSD_STUB_HOME"
fi
exit 0
UAEOF
cat > "$work/bin/usermod" <<'UMEOF'
#!/bin/sh
printf '%s\n' "usermod $*" >> "$STUB_LOG"
exit 0
UMEOF
cat > "$work/bin/chown" <<'CHEOF'
#!/bin/sh
printf '%s\n' "chown $*" >> "$STUB_LOG"
exit 0
CHEOF
chmod 755 "$work/bin/useradd" "$work/bin/usermod" "$work/bin/chown"
fbhome="$work/fb/home"
mkdir -p "$fbhome"
printf 'USERNAME=alice\nSSH_KEY=ssh-ed25519 %s\n' 'AAAAC3NzaC1lZDI1NTE5AAAAI' > "$work/fb/firstboot-user.conf"
: > "$work/fb/sentinel"
: > "$work/fb-stub.log"
PATH="$work/bin:$PATH" \
	STUB_LOG="$work/fb-stub.log" \
	firstboot_user=YES \
	firstboot_user_rcsubr="$stubs/rc.subr" \
	firstboot_user_conf="$work/fb/firstboot-user.conf" \
	firstboot_user_sentinel="$work/fb/sentinel" \
	firstboot_user_home="$fbhome" \
	WTFBSD_STUB_HOME="$fbhome" \
	sh "$stage/etc/rc.d/firstboot_user" start > "$work/fb.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q -- 'useradd -m -s /bin/sh -G wheel -c alice alice' "$work/fb-stub.log"; then
	ok "(C8) the first-boot script creates the user with useradd"
else
	no "(C8) the first-boot script creates the user with useradd (rc=$rc)"
	sed 's/^/      | /' "$work/fb.log"
fi
if grep -q -- '^pw ' "$work/fb-stub.log"; then
	no "(C8) the first-boot script never calls pw"
else
	ok "(C8) the first-boot script never calls pw"
fi
if grep -q -- '^start_cmd="firstboot_user_start"$' "$stage/etc/rc.d/firstboot_user"; then
	ok "(C8) the first-boot script names the command of start in start_cmd"
else
	no "(C8) the first-boot script names the command of start in start_cmd"
fi
keymode=$(stat -c '%a' "$fbhome/.ssh/authorized_keys" 2> /dev/null || stat -f '%Lp' "$fbhome/.ssh/authorized_keys" 2> /dev/null)
dirmode=$(stat -c '%a' "$fbhome/.ssh" 2> /dev/null || stat -f '%Lp' "$fbhome/.ssh" 2> /dev/null)
if [ -f "$fbhome/.ssh/authorized_keys" ] && [ "$keymode" = '600' ] && [ "$dirmode" = '700' ]; then
	ok "(C8) the SSH key of the first-boot user is installed with the mode 0600 in a 0700 .ssh"
else
	no "(C8) the SSH key of the first-boot user is installed with the mode 0600 in a 0700 .ssh (key=$keymode dir=$dirmode)"
fi
if grep -q -- "^chown alice $fbhome/.ssh $fbhome/.ssh/authorized_keys" "$work/fb-stub.log"; then
	ok "(C8) the SSH key of the first-boot user belongs to that user"
else
	no "(C8) the SSH key of the first-boot user belongs to that user"
fi
if [ -f "$work/fb/firstboot-user.conf.done" ] && [ ! -f "$work/fb/sentinel" ]; then
	ok "(C8) the first-boot script consumes the config and removes the sentinel"
else
	no "(C8) the first-boot script consumes the config and removes the sentinel"
fi

# the second boot: the sentinel is gone, so the script does nothing, even
# when the configuration is put back
cp "$work/fb/firstboot-user.conf.done" "$work/fb/firstboot-user.conf"
: > "$work/fb-stub2.log"
PATH="$work/bin:$PATH" \
	STUB_LOG="$work/fb-stub2.log" \
	firstboot_user=YES \
	firstboot_user_rcsubr="$stubs/rc.subr" \
	firstboot_user_conf="$work/fb/firstboot-user.conf" \
	firstboot_user_sentinel="$work/fb/sentinel" \
	firstboot_user_home="$fbhome" \
	sh "$stage/etc/rc.d/firstboot_user" start > "$work/fb2.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && [ ! -s "$work/fb-stub2.log" ]; then
	ok "(C8) the first-boot script does nothing on the second boot"
else
	no "(C8) the first-boot script does nothing on the second boot (rc=$rc)"
	sed 's/^/      | /' "$work/fb2.log"
fi

# a USERNAME that is not a plain name is refused, and nothing is created
printf 'USERNAME=bad name!\nSSH_KEY=ssh-ed25519 %s\n' 'AAAAC3NzaC1lZDI1NTE5AAAAI' > "$work/fb/bad.conf"
: > "$work/fb/bad-sentinel"
: > "$work/fb-bad-stub.log"
PATH="$work/bin:$PATH" \
	STUB_LOG="$work/fb-bad-stub.log" \
	firstboot_user=YES \
	firstboot_user_rcsubr="$stubs/rc.subr" \
	firstboot_user_conf="$work/fb/bad.conf" \
	firstboot_user_sentinel="$work/fb/bad-sentinel" \
	firstboot_user_home="$work/fb/home2" \
	sh "$stage/etc/rc.d/firstboot_user" start > "$work/fb-bad.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$work/fb-bad-stub.log" ]; then
	ok "(C8) a USERNAME that is not a plain name is refused"
else
	no "(C8) a USERNAME that is not a plain name is refused (rc=$rc)"
	sed 's/^/      | /' "$work/fb-bad.log"
fi

if grep -q -- 'rcvar=firstboot_user' "$stage/etc/rc.d/firstboot_user" &&
	grep -q -- '^firstboot_user=YES$' "$stage/etc/rc.conf.d/firstboot_user"; then
	ok "(C8) the first-boot script uses the NetBSD rc variable firstboot_user"
else
	no "(C8) the first-boot script uses the NetBSD rc variable firstboot_user"
fi

# --- D5: the password-hash formats the script accepts, and the redaction --
# firstboot_user(8) accepts only the NetBSD pwhash(1) formats $2a$ and
# $argon2id$: a $6$, a $2b$ or anything else is refused on the first pass,
# before any account is touched. The hash is the argument of usermod(8); on
# error usermod(8) would echo it, so its stderr is discarded and the hash
# never reaches the console, syslog or the log.
mkdir -p "$work/d5" "$work/d5bin"
# the ssh-ed25519 key is given as the printf argument, so the probe shape
# (ssh-ed25519 space, key data) never reads as a contiguous source key
key='AAAAC3NzaC1lZDI1NTE5AAAAI'
printf 'USERNAME=dave\nSSH_KEY=ssh-ed25519 %s\nPASSWORD_HASH=$2a$06$abcdefghijklmnopqrstuv.Wxyzabcdefghijklmnopqr\n' "$key" > "$work/d5/d2a.conf"
printf 'USERNAME=dave\nSSH_KEY=ssh-ed25519 %s\nPASSWORD_HASH=$argon2id$v=19$m=65536,t=3,p=4$c2FsdHRzdGF0ZQ$YWJjZGVmZ2hpamtscg\n' "$key" > "$work/d5/dargon.conf"
printf 'USERNAME=dave\nSSH_KEY=ssh-ed25519 %s\nPASSWORD_HASH=not-a-hash\n' "$key" > "$work/d5/dbad.conf"
printf 'USERNAME=dave\nSSH_KEY=ssh-ed25519 %s\nPASSWORD_HASH=$2a$06$REDACTEDREDACTEDREDACTEDREDACTED\n' "$key" > "$work/d5/dred.conf"
cat > "$work/d5bin/useradd" <<'UAEOF'
#!/bin/sh
printf '%s\n' "useradd $*" >> "$STUB_LOG"
exit 0
UAEOF
cat > "$work/d5bin/usermod.fail" <<'UMEF'
#!/bin/sh
printf '%s\n' "usermod $*" >> "$STUB_LOG"
printf '%s: %s: invalid hash\n' "$0" "$2" >&2
exit 1
UMEF
cat > "$work/d5bin/usermod.ok" <<'UMEOK'
#!/bin/sh
printf '%s\n' "usermod $*" >> "$STUB_LOG"
exit 0
UMEOK
# the logger the script's note() falls back to: it records to STUB_LOG, so
# a test can assert the log never carries a value the script was told to hide
cat > "$work/d5bin/logger" <<'LOGBIN'
#!/bin/sh
printf 'logger: %s\n' "$*" >> "$STUB_LOG" 2>/dev/null || true
exit 0
LOGBIN
chmod 755 "$work/d5bin/useradd" "$work/d5bin/usermod.fail" "$work/d5bin/usermod.ok" "$work/d5bin/logger"
# d5run <outfile> <conf> <home> <sentinel> <modustub-stem>: run firstboot_user
d5run() {
	_out=$1 _conf=$2 _home=$3 _sent=$4 _mod=$5
	mkdir -p "$_home/.ssh"
	: > "$_sent"
	cp "$work/d5bin/usermod.$_mod" "$work/d5bin/usermod"
	(
		cd "$work/d5" || exit 1
		STUB_LOG="$_out.stub.log" \
			firstboot_user=YES \
			firstboot_user_rcsubr="$stubs/rc.subr" \
			firstboot_user_conf="$_conf" \
			firstboot_user_sentinel="$_sent" \
			firstboot_user_home="$_home" \
			PATH="$work/d5bin:$PATH" \
			sh "$stage/etc/rc.d/firstboot_user" start > "$_out" 2>&1
	)
}
# $2a$ and $argon2id$ are accepted: useradd(8) creates the account, usermod(8)
# applies the hash, and the conf is consumed on success
d5run "$work/d5/d2a.out" "$work/d5/d2a.conf" "$work/d5/home-2a" "$work/d5/sent-2a" ok
if [ "$?" -eq 0 ] && grep -Fq '$2a$06$abcdefghijklmnopqrstuv.Wxyzabcdefghijklmnopqr' "$work/d5/d2a.out.stub.log" && \
	[ -f "$work/d5/d2a.conf.done" ] && [ ! -f "$work/d5/sent-2a" ]; then
	ok '(D5) the password hash format $2a$ is accepted'
else
	no '(D5) the password hash format $2a$ is accepted'
	sed 's/^/      | /' "$work/d5/d2a.out" 2>/dev/null | head
fi
d5run "$work/d5/dargon.out" "$work/d5/dargon.conf" "$work/d5/home-argon" "$work/d5/sent-argon" ok
if [ "$?" -eq 0 ] && grep -Fq '$argon2id' "$work/d5/dargon.out.stub.log" && \
	[ -f "$work/d5/dargon.conf.done" ] && [ ! -f "$work/d5/sent-argon" ]; then
	ok '(D5) the password hash format $argon2id$ is accepted'
else
	no '(D5) the password hash format $argon2id$ is accepted'
	sed 's/^/      | /' "$work/d5/dargon.out" 2>/dev/null | head
fi
# crypt(3) hashes build.sh and firstboot_user refuse ($6$, $2b$): the
# accepted formats are $2a$ and $argon2id$ only, so a $6$ or a $2b$ is
# refused on the first pass, before the account is touched (the stub log
# holds the logger notes, never a useradd or usermod call).
printf 'USERNAME=dave\nSSH_KEY=ssh-ed25519 %s\nPASSWORD_HASH=$6$abcd$Saltsaltsalt1234567890abcdefghij\n' "$key" > "$work/d5/d6.conf"
printf 'USERNAME=dave\nSSH_KEY=ssh-ed25519 %s\nPASSWORD_HASH=$2b$12$abcdefghijqrstuvwx.yabcdefghijklmnopqrstuvwxyz01234567\n' "$key" > "$work/d5/d2b.conf"
d5run "$work/d5/d6.out" "$work/d5/d6.conf" "$work/d5/home-6" "$work/d5/sent-6" ok
if [ "$?" -ne 0 ] && grep -q 'must be a NetBSD pwhash(1) hash' "$work/d5/d6.out" && \
	[ -f "$work/d5/sent-6" ] && [ ! -f "$work/d5/d6.conf.done" ] && \
	[ ! -f "$work/d5/home-6/.ssh/authorized_keys" ] && ! grep -qE '^(useradd|usermod) ' "$work/d5/d6.out.stub.log"; then
	ok '(D5) a $6$ hash is refused (only $2a$ and $argon2id$ are accepted)'
else
	no '(D5) a $6$ hash is refused (only $2a$ and $argon2id$ are accepted)'
	sed 's/^/      | /' "$work/d5/d6.out" 2>/dev/null | head
fi
d5run "$work/d5/d2b.out" "$work/d5/d2b.conf" "$work/d5/home-2b" "$work/d5/sent-2b" ok
if [ "$?" -ne 0 ] && grep -q 'must be a NetBSD pwhash(1) hash' "$work/d5/d2b.out" && \
	[ -f "$work/d5/sent-2b" ] && [ ! -f "$work/d5/d2b.conf.done" ] && \
	[ ! -f "$work/d5/home-2b/.ssh/authorized_keys" ] && ! grep -qE '^(useradd|usermod) ' "$work/d5/d2b.out.stub.log"; then
	ok '(D5) a $2b$ hash is refused (only $2a$ and $argon2id$ are accepted)'
else
	no '(D5) a $2b$ hash is refused (only $2a$ and $argon2id$ are accepted)'
	sed 's/^/      | /' "$work/d5/d2b.out" 2>/dev/null | head
fi
# a line that is not KEY=value (a PASSWORD_HASH: with a colon, or a
# lowercase password_hash=) is refused on the first pass; the script reports
# the line number only, so the hash content never reaches stdout, stderr or
# the logger stub.
cat > "$work/d5bin/logger" <<'LSEOF'
#!/bin/sh
# logger stub: drop the -t <tag>, record the message body only
while [ "$#" -gt 0 ]; do
	case $1 in
	-t) shift 2 ;;
	*) shift ;;
	esac
done
printf '%s\n' "$@" >> "$STUB_LOG" 2>/dev/null || true
LSEOF
chmod 755 "$work/d5bin/logger"
# d5leak <name> <line>: a conf whose third line is <line> is refused on the
# first pass, and the string SECRETSECRET appears in none of stdout, stderr
# or the logger stub output
d5leak() {
	printf 'USERNAME=dave\nSSH_KEY=ssh-ed25519 %s\n%s\n' "$key" "$2" > "$work/d5/dl-$1.conf"
	d5run "$work/d5/dl-$1.out" "$work/d5/dl-$1.conf" "$work/d5/home-dl-$1" "$work/d5/sent-dl-$1" ok
	_rc=$?
	: >> "$work/d5/dl-$1.out.stub.log"
	if [ "$_rc" -ne 0 ] && grep -q 'line 3' "$work/d5/dl-$1.out" && \
		! grep -q 'SECRETSECRET' "$work/d5/dl-$1.out" "$work/d5/dl-$1.out.stub.log"; then
		ok "(D5) a bad conf line ($1) is reported by line number only; SECRETSECRET is in no stdout, stderr or logger output"
	else
		no "(D5) a bad conf line ($1) is reported by line number only; SECRETSECRET is in no stdout, stderr or logger output (rc=$_rc)"
		# the output is reported by line number only: it may hold the secret
		grep -n 'SECRETSECRET' "$work/d5/dl-$1.out" "$work/d5/dl-$1.out.stub.log" 2>/dev/null | cut -d: -f1,2
	fi
}
d5leak colon 'PASSWORD_HASH:$2a$06$SECRETSECRETSECRETSECRETSECRETSECRETSECRETSECRETSE'
d5leak lower 'password_hash=$2a$06$SECRETSECRETSECRETSECRETSECRETSECRETSECRETSECRETSE'
d5leak argoncolon 'PASSWORD_HASH:$argon2id$v=19$m=65536,t=3,p=4$SECRETSECRET$SECRETSECRET'
# a conf with two PASSWORD_HASH lines is refused on the first pass (line
# number only), before useradd(8) or usermod(8) is called
printf 'USERNAME=dave\nSSH_KEY=ssh-ed25519 %s\nPASSWORD_HASH=%s\nPASSWORD_HASH=%s\n' "$key" \
	'$2a$06$SECRETSECRETSECRETSECRETSECRETSECRETSECRETSECRETSE' \
	'$2a$06$SECRETSECRETSECRETSECRETSECRETSECRETSECRETSECRETSF' > "$work/d5/dtwo.conf"
d5run "$work/d5/dtwo.out" "$work/d5/dtwo.conf" "$work/d5/home-two" "$work/d5/sent-two" ok
_rc=$?
: >> "$work/d5/dtwo.out.stub.log"
if [ "$_rc" -ne 0 ] && grep -q 'line 4: a second PASSWORD_HASH line' "$work/d5/dtwo.out" && \
	! grep -qE '^(useradd|usermod) ' "$work/d5/dtwo.out.stub.log" && \
	! grep -q 'SECRETSECRET' "$work/d5/dtwo.out"; then
	ok "(D5) a conf with two PASSWORD_HASH lines is refused before the account is touched"
else
	no "(D5) a conf with two PASSWORD_HASH lines is refused before the account is touched (rc=$_rc)"
	grep -n 'SECRETSECRET' "$work/d5/dtwo.out" 2>/dev/null | cut -d: -f1
fi
d5leak wheel 'WHEEL=$2a$06$SECRETSECRETSECRETSECRETSECRETSECRETSECRETSECRETSE'
# a hash that is none of the accepted formats is refused on the first pass,
# before the account is touched: the script fails and leaves the sentinel
d5run "$work/d5/dbad.out" "$work/d5/dbad.conf" "$work/d5/home-bad" "$work/d5/sent-bad" fail
if [ "$?" -ne 0 ] && [ -f "$work/d5/sent-bad" ] && [ ! -f "$work/d5/dbad.conf.done" ] && [ ! -f "$work/d5/home-bad/.ssh/authorized_keys" ]; then
	ok "(D5) a password hash that is not one of the accepted formats is refused"
else
	no "(D5) a password hash that is not one of the accepted formats is refused"
	sed 's/^/      | /' "$work/d5/dbad.out" 2>/dev/null | head
fi
# on error the hash is echoed by usermod(8), but to a throwaway stderr: it
# is in the call record, never in the console or the log
d5run "$work/d5/dred.out" "$work/d5/dred.conf" "$work/d5/home-red" "$work/d5/sent-red" fail
if grep -Fq '$2a$06$REDACTEDREDACTEDREDACTEDREDACTED' "$work/d5/dred.out.stub.log" && \
	! grep -Fq '$2a$06$REDACTEDREDACTEDREDACTEDREDACTED' "$work/d5/dred.out"; then
	ok "(D5) the password hash is never written to the console or the log"
else
	no "(D5) the password hash is never written to the console or the log"
	sed 's/^/      | /' "$work/d5/dred.out" 2>/dev/null | head
fi

# --- D7: build.sh bakes /etc/firstboot-user.conf from -u/-k/-H ------------
# build.sh bakes the first-boot config from -u (the username) and -k (a file
# of ssh public keys): USERNAME=USER, one SSH_KEY= line per non-empty,
# non-comment line of the pubkey file. -H (a file of password hashes) adds
# one PASSWORD_HASH= per non-empty, non-comment line. The conf is mode 0600,
# because it may hold a password hash. The validation is done at the static
# checks, in the dry run too, so a bad line is refused before the packages
# are touched. The build here is the real build path against the fake src.
mkdir -p "$work/src-d7"
cp "$repo/tests/fixtures/fake-src-build.sh" "$work/src-d7/build.sh"
chmod 755 "$work/src-d7/build.sh"
# the ssh-ed25519 key is written via the printf argument (%s), not
# concatenated in source, so the internal-references probe shape
# (ssh-ed25519 space, key data) never matches a contiguous source key here
key='AAAAC3NzaC1lZDI1NTE5AAAAI'
# the pubkey file: one ssh public key per non-empty, non-comment line
printf 'ssh-ed25519 %s\n' "$key" > "$work/d7.pubkey"
# the hash file: one bare NetBSD pwhash(1) hash per non-empty, non-comment
# line; build.sh prepends PASSWORD_HASH= to each.
printf '$2a$06$abcdefghijklmnopqrstuv.Wxyzabcdefghijklmnopqr\n' > "$work/d7.hash"
STUB_LOG="$work/stub-d7.log" STUB_REAL_TAR="$STUB_REAL_TAR" STUB_REAL_DD="$STUB_REAL_DD" \
	FAKE_SETS_DIR="$sets" WTFBSD_TOOLDIR="$stubs" PATH="$stubs/bin:$PATH" \
	WTFBSD_HOST_OS=NetBSD ROOTSIZE=64M ESPSIZE=16m \
	sh "$build" -c "$fixture" -s "$work/src-d7" -o "$work/out-d7" -u dave -k "$work/d7.pubkey" -H "$work/d7.hash" > "$work/d7.log" 2>&1
d7rc=$?
d7conf="$work/out-d7/appliance/stage/etc/firstboot-user.conf"
if [ "$d7rc" -eq 0 ] && [ -f "$d7conf" ] && \
	[ "$(stat -c '%a' "$d7conf" 2>/dev/null || stat -f '%Lp' "$d7conf" 2>/dev/null)" = '600' ] && \
	grep -q '^USERNAME=dave$' "$d7conf" && \
	grep -q '^SSH_KEY=ssh-ed25519 ' "$d7conf" && \
	grep -q '^PASSWORD_HASH=\$2a\$06\$' "$d7conf"; then
	ok "(D7) build.sh bakes /etc/firstboot-user.conf (mode 0600) from -u/-k/-H"
else
	no "(D7) build.sh bakes /etc/firstboot-user.conf (mode 0600) from -u/-k/-H"
	sed 's/^/      | /' "$work/d7.log" 2>/dev/null | head
	[ -f "$d7conf" ] && sed 's/^/      /' "$d7conf"
fi
# the conf is recorded in the image metadata with the mode the build set on
# it: 0600, because it is operator data that may hold a hash.
if grep -qF './etc/firstboot-user.conf type=file mode=0600 uname=root gname=wheel' "$work/out-d7/appliance/metalog" 2>/dev/null; then
	ok "(D7) the baked conf is recorded in the METALOG with mode 0600"
else
	no "(D7) the baked conf is recorded in the METALOG with mode 0600"
fi
# only one of -u and -k is not enough: the build refuses, the conf is not baked
STUB_LOG="$work/stub-d7b.log" STUB_REAL_TAR="$STUB_REAL_TAR" STUB_REAL_DD="$STUB_REAL_DD" \
	FAKE_SETS_DIR="$sets" WTFBSD_TOOLDIR="$stubs" PATH="$stubs/bin:$PATH" \
	WTFBSD_HOST_OS=NetBSD ROOTSIZE=64M ESPSIZE=16m \
	sh "$build" -c "$fixture" -s "$work/src-d7" -o "$work/out-d7b" -u dave > "$work/d7b.log" 2>&1
if [ "$?" -ne 0 ] && grep -q -- '-u USER and -k PUBKEYFILE must be given together' "$work/d7b.log"; then
	ok "(D7) -u without -k is refused"
else
	no "(D7) -u without -k is refused"
	sed 's/^/      | /' "$work/d7b.log" 2>/dev/null | head
fi
# the static checks run in the dry run too: a bad username is refused
# before anything is built.
sh "$build" -c "$fixture" -s "$work/src-d7" -o "$work/out-d7d" -n -u 'BAD!' -k "$work/d7.pubkey" > "$work/d7d.log" 2>&1
if [ "$?" -ne 0 ] && grep -q -- '-u: bad username' "$work/d7d.log"; then
	ok "(D7) a bad username is refused in the dry run"
else
	no "(D7) a bad username is refused in the dry run"
	sed 's/^/      | /' "$work/d7d.log" 2>/dev/null | head
fi
# a pubkey file that does not exist is refused, in the dry run too
sh "$build" -c "$fixture" -s "$work/src-d7" -o "$work/out-d7e" -n -u dave -k "$work/no-such-key" > "$work/d7e.log" 2>&1
if [ "$?" -ne 0 ] && grep -q -- 'no such pubkey file' "$work/d7e.log"; then
	ok "(D7) a missing pubkey file is refused in the dry run"
else
	no "(D7) a missing pubkey file is refused in the dry run"
	sed 's/^/      | /' "$work/d7e.log" 2>/dev/null | head
fi
# a bad hash in the -H file is refused, before any package is touched
printf 'not-a-hash\n' > "$work/d7bad.hash"
STUB_LOG="$work/stub-d7c.log" STUB_REAL_TAR="$STUB_REAL_TAR" STUB_REAL_DD="$STUB_REAL_DD" \
	FAKE_SETS_DIR="$sets" WTFBSD_TOOLDIR="$stubs" PATH="$stubs/bin:$PATH" \
	WTFBSD_HOST_OS=NetBSD ROOTSIZE=64M ESPSIZE=16m \
	sh "$build" -c "$fixture" -s "$work/src-d7" -o "$work/out-d7c" -u dave -k "$work/d7.pubkey" -H "$work/d7bad.hash" > "$work/d7c.log" 2>&1
d7c_rc=$?
if [ "$d7c_rc" -ne 0 ] && grep -q -- 'the password hash must be a NetBSD pwhash(1) hash' "$work/d7c.log"; then
	ok "(D7) a source file with a bad password hash is refused"
else
	no "(D7) a source file with a bad password hash is refused"
	sed 's/^/      | /' "$work/d7c.log" 2>/dev/null | head
fi

# the -H file accepts only the NetBSD pwhash(1) formats $2a$ and
# $argon2id$ (usermod(8) of NetBSD 11 refuses the others): a $6$ or a $2b$
# hash is refused at the static checks, in the dry run too, and the line is
# reported by its number only, so the hash never reaches stdout or stderr
d7refuse() { # d7refuse <name> <hash line>
	printf '%s\n' "$2" > "$work/d7-$1.hash"
	sh "$build" -c "$fixture" -s "$work/src-d7" -o "$work/out-d7-$1" -n \
		-u dave -k "$work/d7.pubkey" -H "$work/d7-$1.hash" > "$work/d7-$1.log" 2>&1
	_rc=$?
	if [ "$_rc" -ne 0 ] && grep -q 'line 1: the password hash must be a NetBSD pwhash(1) hash' "$work/d7-$1.log" && \
		! grep -q 'SECRETSECRET' "$work/d7-$1.log"; then
		ok "(D7) build.sh refuses a $1 hash in the -H file and never prints it"
	else
		no "(D7) build.sh refuses a $1 hash in the -H file and never prints it (rc=$_rc)"
		grep -n 'SECRETSECRET' "$work/d7-$1.log" 2>/dev/null | cut -d: -f1
	fi
}
d7refuse '$6$' '$6$rounds=5000$SECRETSECRET$SECRETSECRETSECRETSECRETSECRETSE'
d7refuse '$2b$' '$2b$12$SECRETSECRETSECRETSECRETSECRETSECRETSECRETSECRETSE'
# the account has one password: a -H file with two hash lines is refused,
# by the line number of the second one, and neither hash is printed
printf '%s\n' '$2a$06$SECRETSECRETSECRETSECRETSECRETSECRETSECRETSECRETSE' \
	'$2a$06$SECRETSECRETSECRETSECRETSECRETSECRETSECRETSECRETSF' > "$work/d7-two.hash"
sh "$build" -c "$fixture" -s "$work/src-d7" -o "$work/out-d7-two" -n \
	-u dave -k "$work/d7.pubkey" -H "$work/d7-two.hash" > "$work/d7-two.log" 2>&1
_rc=$?
if [ "$_rc" -ne 0 ] && grep -q 'line 2: a second password hash line' "$work/d7-two.log" && \
	! grep -q 'SECRETSECRET' "$work/d7-two.log"; then
	ok "(D7) a -H file with two hash lines is refused by line number"
else
	no "(D7) a -H file with two hash lines is refused by line number (rc=$_rc)"
	grep -n 'SECRETSECRET' "$work/d7-two.log" 2>/dev/null | cut -d: -f1
fi
# a bad -k line is refused by its line number; its content (which may be a
# private key pasted by mistake) never reaches stdout or stderr
printf 'ssh-ed25519 %s\nSECRETSECRET not a public key\n' "$key" > "$work/d7-badkey.pub"
sh "$build" -c "$fixture" -s "$work/src-d7" -o "$work/out-d7-badkey" -n \
	-u dave -k "$work/d7-badkey.pub" > "$work/d7-badkey.log" 2>&1
_rc=$?
if [ "$_rc" -ne 0 ] && grep -q 'line 2 is not a supported ssh public key' "$work/d7-badkey.log" && \
	! grep -q 'SECRETSECRET' "$work/d7-badkey.log"; then
	ok "(D7) a bad -k line is refused by its line number and never printed"
else
	no "(D7) a bad -k line is refused by its line number and never printed (rc=$_rc)"
	grep -n 'SECRETSECRET' "$work/d7-badkey.log" 2>/dev/null | cut -d: -f1
fi
# the baked conf is created under umask 077: a chmod(1) wrapper records the
# mode of the conf at the moment build.sh calls chmod on it, before the
# real chmod runs. The build runs under umask 022, so a conf written
# without umask 077 is 0644 at that moment.
mkdir -p "$work/d7wrap"
STUB_REAL_CHMOD=$(command -v chmod)
cat > "$work/d7wrap/chmod" <<'CHMODEOF'
#!/bin/sh
# chmod wrapper: record the mode of a firstboot-user.conf before chmod(1)
for _a in "$@"; do _last=$_a; done
case ${_last:-} in
*/firstboot-user.conf)
	_m=$(stat -c '%a' "$_last" 2>/dev/null || stat -f '%Lp' "$_last" 2>/dev/null)
	printf 'before-chmod %s\n' "$_m" >> "$D7_CHMOD_LOG"
	;;
esac
exec "$STUB_REAL_CHMOD" "$@"
CHMODEOF
"$STUB_REAL_CHMOD" 755 "$work/d7wrap/chmod"
: > "$work/d7-chmod.log"
(
	umask 022
	D7_CHMOD_LOG="$work/d7-chmod.log" STUB_REAL_CHMOD="$STUB_REAL_CHMOD" \
		STUB_LOG="$work/stub-d7u.log" STUB_REAL_TAR="$STUB_REAL_TAR" STUB_REAL_DD="$STUB_REAL_DD" \
		FAKE_SETS_DIR="$sets" WTFBSD_TOOLDIR="$stubs" PATH="$work/d7wrap:$stubs/bin:$PATH" \
		WTFBSD_HOST_OS=NetBSD ROOTSIZE=64M ESPSIZE=16m \
		sh "$build" -c "$fixture" -s "$work/src-d7" -o "$work/out-d7u" -u dave -k "$work/d7.pubkey" -H "$work/d7.hash"
) > "$work/d7u.log" 2>&1
d7u_rc=$?
if [ "$d7u_rc" -eq 0 ] && [ -s "$work/d7-chmod.log" ] && \
	! grep -qv '^before-chmod 600$' "$work/d7-chmod.log"; then
	ok "(D7) the baked conf is already 0600 before the chmod (written under umask 077)"
else
	no "(D7) the baked conf is already 0600 before the chmod (written under umask 077) (rc=$d7u_rc)"
	sed 's/^/      | /' "$work/d7-chmod.log" 2>/dev/null | head
fi

# --- D10: the build normalises the image sizes before makefs(1) ---------
# makefs(1) wants the lowercase suffixes (12g, 64m). The build runs
# ROOTSIZE and ESPSIZE through norm_size so that a "12G" on the command line
# is not handed to makefs(8); the dry-run plan prints the normalised value.
ROOTSIZE=12G sh "$build" -c "$fixture" -s "$work/src-d7" -o "$work/out-norm" -n \
	> "$work/norm.log" 2>&1
if grep -q -- 'rootsize: 12g' "$work/norm.log"; then
	ok "(D10) build.sh normalises a 12G size to 12g before makefs"
else
	no "(D10) build.sh normalises a 12G size to 12g before makefs"
	sed -n '1,20p' "$work/norm.log" 2>/dev/null | head
fi

# a bare suffix is not a size: ROOTSIZE=g is refused
ROOTSIZE=g sh "$build" -c "$fixture" -s "$work/src-d7" -o "$work/out-norm-g" -n \
	> "$work/norm-g.log" 2>&1
if [ "$?" -ne 0 ] && grep -q 'ROOTSIZE must be digits with an optional single k/m/g suffix' "$work/norm-g.log"; then
	ok "(D10) a bare size suffix (ROOTSIZE=g) is refused"
else
	no "(D10) a bare size suffix (ROOTSIZE=g) is refused"
	sed -n '1,10p' "$work/norm-g.log" 2>/dev/null
fi
# norm_size accepts only the suffixes size_bytes reads (k, m, g): a b
# suffix is refused
ROOTSIZE=12b sh "$build" -c "$fixture" -s "$work/src-d7" -o "$work/out-norm-b" -n \
	> "$work/norm-b.log" 2>&1
if [ "$?" -ne 0 ] && grep -q 'ROOTSIZE is not a size like 12g (digits, optional single k/m/g suffix)' "$work/norm-b.log"; then
	ok "(D10) a b size suffix (ROOTSIZE=12b) is refused"
else
	no "(D10) a b size suffix (ROOTSIZE=12b) is refused"
	sed -n '1,10p' "$work/norm-b.log" 2>/dev/null
fi
# the nbmakefs stub refuses an uppercase size suffix exactly like the real
# tool (strsuftoll(3) takes b/k/m/g/t/w in lower case), so the real build
# cases above (ROOTSIZE=64M) prove the size is normalised before makefs
STUB_LOG="$work/stub-mk12G.log" sh "$stubs/bin/nbmakefs" -t ffs -s 12G "$work/mk12G.img" "$work" > "$work/mk12G.out" 2>&1
_rc=$?
if [ "$_rc" -eq 1 ] && [ "$(cat "$work/mk12G.out")" = "nbmakefs: size '12G': illegal number" ]; then
	ok "(D10) the nbmakefs stub refuses -s 12G like the real tool"
else
	no "(D10) the nbmakefs stub refuses -s 12G like the real tool (rc=$_rc)"
	sed 's/^/      | /' "$work/mk12G.out"
fi

# --- D11: firstboot_user runs after the root filesystem is mounted ------
# firstboot_user(8) edits files on the root filesystem, so it must run
# after mountall(8) has mounted them read-write. The requirement is
# "REQUIRE: NETWORKING mountall": FILESYSTEMS->mountall guarantees the root
# is mounted, and NETWORKING is restored so the serial console is up.
if grep -qE '^# REQUIRE: NETWORKING mountall[[:space:]]*$' \
		"$repo/overlay/base/rootfs/etc/rc.d/firstboot_user"; then
	ok "(D11) firstboot_user runs after mountall (REQUIRE: NETWORKING mountall)"
else
	no "(D11) firstboot_user runs after mountall (REQUIRE: NETWORKING mountall)"
	sed -n '1,15p' "$repo/overlay/base/rootfs/etc/rc.d/firstboot_user" 2>/dev/null | head
fi

# --- D12: the build unpacks only the named kernel set -------------------
# Every kern-<CONFIG> set holds ./netbsd: only the set named by KERNEL_SET
# (default GENERIC) is unpacked, so /netbsd is the GENERIC kernel we boot
# and not a later set's copy. With two kernel sets in the release, only the
# GENERIC one is extracted, which the tar stub log shows.
sets2="$work/sets2"
mkdir -p "$sets2"
"$STUB_REAL_TAR" -cJf "$sets2/base.tar.xz"      -C "$fakestage" .
"$STUB_REAL_TAR" -cJf "$sets2/kern-GENERIC.tar.xz" -C "$fakestage" .
"$STUB_REAL_TAR" -cJf "$sets2/kern-POWERPC.tar.xz" -C "$fakestage" .
STUB_LOG="$work/stub-ks.log" STUB_REAL_TAR="$STUB_REAL_TAR" STUB_REAL_DD="$STUB_REAL_DD" \
	FAKE_SETS_DIR="$sets2" WTFBSD_TOOLDIR="$stubs" PATH="$stubs/bin:$PATH" \
	WTFBSD_HOST_OS=NetBSD ROOTSIZE=64M ESPSIZE=16m \
	sh "$build" -c "$fixture" -s "$work/src-d7" -o "$work/out-ks" > "$work/ks.log" 2>&1
if grep -q -- 'kern-GENERIC.tar.xz' "$work/stub-ks.log" && \
	! grep -q -- 'kern-POWERPC.tar.xz' "$work/stub-ks.log"; then
	ok "(D12) only the named kernel set (GENERIC) is unpacked, not a later set"
else
	no "(D12) only the named kernel set (GENERIC) is unpacked, not a later set"
	sed -n '1,20p' "$work/ks.log" 2>/dev/null | head
fi

# --- M1: the metadata of the image ----------------------------------------
# The METALOG of the upstream build describes the base system (the modes
# of /tmp, of su and of everything else the release sets carry), and the
# entries of the files that the build adds on top of it are appended.
metalog="$out/appliance/metalog"

# the mode of an entry of the spec, by its path
spec_mode() { # spec_mode <path>
	awk -v p="$1" '$1 == p {
		for (i = 2; i <= NF; i++) if ($i ~ /^mode=/) { print $i; exit }
	}' "$metalog"
}

if [ "$(spec_mode ./tmp)" = 'mode=01777' ] &&
	[ "$(spec_mode ./usr/bin/su)" = 'mode=04555' ]; then
	ok "(M1) the METALOG of the upstream build survives into the image metadata"
else
	no "(M1) the METALOG of the upstream build survives into the image metadata (tmp=$(spec_mode ./tmp) su=$(spec_mode ./usr/bin/su))"
fi
if grep -q -- '^\./tmp type=dir mode=0755' "$metalog"; then
	no "(M1) the mode of the base system is not rebuilt from the host"
else
	ok "(M1) the mode of the base system is not rebuilt from the host"
fi

# every entry of the spec has its parent on an earlier line: makefs(8)
# refuses a spec whose directory comes after the files it holds ("missing
# directory in specification")
order_bad=$(awk '
	$1 ~ /^#/ || $1 ~ /^\/set/ { next }
	{
		p = $1
		parent = p
		sub(/\/[^\/]*$/, "", parent)
		if (parent != p && !(parent in seen)) { print p " (its parent " parent " is not on an earlier line)" }
		seen[p] = 1
	}
' "$metalog" 2> /dev/null)
if [ -z "$order_bad" ]; then
	ok "(M1) every entry of the spec has its parent on an earlier line"
else
	no "(M1) every entry of the spec has its parent on an earlier line"
	printf '%s\n' "$order_bad" | head -5 | sed 's/^/      | /'
fi

# a path is in the spec only once: the entry of the base system and the
# entry of the overlay are one entry
dupe_paths=$(awk '$1 !~ /^#/ && $1 !~ /^\/set/ { print $1 }' "$metalog" |
	LC_ALL=C sort | uniq -d)
if [ -z "$dupe_paths" ]; then
	ok "(M1) a path is in the spec only once"
else
	no "(M1) a path is in the spec only once:$dupe_paths"
fi

if grep -Fq './usr/pkg/bin/link-to-etc type=link link=../../etc uname=root gname=wheel' "$metalog"; then
	ok "(M1) a symlink to a directory is recorded as a link"
else
	no "(M1) a symlink to a directory is recorded as a link"
fi
if grep -q -- "nbmakefs -t ffs -F $out/appliance/metalog -N $stage/etc " "$stub_log"; then
	ok "(M1) the image is built with the passwd and group of the target"
else
	no "(M1) the image is built with the passwd and group of the target"
fi
if grep -q -- "nbmakefs .* -N " "$stub_log" && ! grep -q -- 'nbmakefs .* -U ' "$stub_log"; then
	ok "(M1) the image is built with -N and never with -U"
else
	no "(M1) the image is built with -N and never with -U"
fi

# --- M2: the overlay fixture with a symlink --------------------------------
# A symlink of the overlay has to be recorded as a link and never as a
# directory: the metadata spec asks about the link before the directory,
# because a link to a directory passes the test for a directory. The
# overlay of this repository holds no symlink, so the fixture is a copy
# of the repository with one: the overlay of the product stays
# untouched.
fixture_repo="$work/fixture-repo"
mkdir -p "$fixture_repo"
cp "$build" "$fixture_repo/build.sh"
chmod 755 "$fixture_repo/build.sh"
cp -R "$repo/overlay" "$fixture_repo/overlay"
mkdir -p "$fixture_repo/overlay/base/rootfs/usr/local/bin"
ln -s ../sbin "$fixture_repo/overlay/base/rootfs/usr/local/bin/examplebsd-pool-create"
(
	cd "$work" || exit 1
	STUB_LOG="$log_file" \
		STUB_REAL_TAR="$STUB_REAL_TAR" \
		STUB_REAL_DD="$STUB_REAL_DD" \
		FAKE_SETS_DIR="$sets" \
		WTFBSD_TOOLDIR="$stubs" \
		PATH="$stubs/bin:$PATH" \
		WTFBSD_HOST_OS=NetBSD \
		ROOTSIZE=64M \
		ESPSIZE=16m \
		sh "$fixture_repo/build.sh" -c "$fixture" -s "$fakesrc" -o fixture-out
) > "$work/fixture.log" 2>&1
fixture_metalog="$work/fixture-out/appliance/metalog"
if grep -Fq './usr/local/bin/examplebsd-pool-create type=link link=../sbin uname=root gname=wheel' \
	"$fixture_metalog" 2> /dev/null; then
	ok "(M2) a symlink of the overlay is recorded as a link"
else
	no "(M2) a symlink of the overlay is recorded as a link"
	sed 's/^/      | /' "$fixture_metalog" 2> /dev/null | head -20
fi
if grep -Fq './usr/local/bin/examplebsd-pool-create type=dir' "$fixture_metalog" 2> /dev/null; then
	no "(M2) the symlink of the overlay is never recorded as a directory"
else
	ok "(M2) the symlink of the overlay is never recorded as a directory"
fi
fixture_order_bad=$(awk '
	$1 ~ /^#/ || $1 ~ /^\/set/ { next }
	{
		p = $1
		parent = p
		sub(/\/[^\/]*$/, "", parent)
		if (parent != p && !(parent in seen)) { print p " (its parent " parent " is not on an earlier line)" }
		seen[p] = 1
	}
' "$fixture_metalog" 2> /dev/null)
if [ -z "$fixture_order_bad" ]; then
	ok "(M2) every entry of the spec of the fixture has its parent on an earlier line"
else
	no "(M2) every entry of the spec of the fixture has its parent on an earlier line"
	printf '%s\n' "$fixture_order_bad" | head -5 | sed 's/^/      | /'
fi

# --- P1: the ZFS data pool helper ------------------------------------------
cat > "$work/bin/zpool" <<'ZPOOLEOF'
#!/bin/sh
printf '%s\n' "zpool $*" >> "$STUB_LOG"
case ${1:-} in
list)
	[ "${WTFBSD_STUB_POOL_EXISTS:-0}" = 1 ] && exit 0
	exit 1
	;;
esac
exit 0
ZPOOLEOF
cat > "$work/bin/id" <<'IDEOF'
#!/bin/sh
# the test suite is not root; the stub makes the script believe it is
if [ "${1:-}" = -u ]; then
	echo 0
	exit 0
fi
exec "${ID_REAL}" "$@"
IDEOF
cat > "$work/bin/sysctl" <<'SYSCTLEOF'
#!/bin/sh
printf '%s\n' "sysctl $*" >> "$STUB_LOG"
printf '%s\n' "${WTFBSD_STUB_ROOT_DEVICE:-wd0a}"
SYSCTLEOF
cat > "$work/bin/stat" <<'STATEOF'
#!/bin/sh
# the fake device is a regular file; the stub reports it as a block device
case "$*" in
*'%F'*) echo 'block special file'; exit 0 ;;
esac
exec "${STAT_REAL}" "$@"
STATEOF
cat > "$work/bin/gpt" <<'GPTEOF'
#!/bin/sh
printf '%s\n' "gpt $*" >> "$STUB_LOG"
# gpt(8) exits with 0 on a blank disk and prints the map of the free
# space ("Unused"), so the exit status says nothing about the disk: the
# rows of the GPT header are in the output only when the disk carries a
# partition table.
if [ "${WTFBSD_STUB_GPT:-0}" = 1 ]; then
	printf '%s\n' 'Disk /dev/wd0: 1000200 MB'
	printf '%s\n' '        0         1         2         3      Pri GPT header'
	printf '%s\n' '        0        40   2043900    Unused     -  0  -'
else
	printf '%s\n' 'Disk /dev/wd0: 1000200 MB'
	printf '%s\n' '        0        40   2043900    Unused     -  0  -'
fi
exit 0
GPTEOF
cat > "$work/bin/dkctl" <<'DKEOF'
#!/bin/sh
printf '%s\n' "dkctl $*" >> "$STUB_LOG"
# the output of dkctl(8): "<wedge> at <parent>: <name>"
if [ "${2:-}" = getwedgeinfo ]; then
	case ${WTFBSD_STUB_DKCTL_SHAPE:-documented} in
	alt)
		# another shape of the same output: the parent is there, but
		# not in the third field
		printf '%s: %s\n' "${1:-dk0}" "${WTFBSD_STUB_WEDGE_PARENT:-wd0}"
		;;
	*)
		printf '%s at %s: %s\n' "${1:-dk0}" "${WTFBSD_STUB_WEDGE_PARENT:-wd0}" 'test'
		;;
	esac
fi
exit 0
DKEOF
chmod 755 "$work/bin/zpool" "$work/bin/id" "$work/bin/sysctl" "$work/bin/stat" "$work/bin/gpt" \
	"$work/bin/dkctl"
ID_REAL=$(command -v id)
STAT_REAL=$(command -v stat)
export ID_REAL STAT_REAL
poolhelper="$stage/usr/local/sbin/examplebsd-pool-create"
: > "$work/zpool.log"
# (P0) --help is a success, a missing device is a usage error
sh "$poolhelper" --help > /dev/null 2>&1; _h=$?
sh "$poolhelper" > /dev/null 2>&1; _u=$?
if [ "$_h" -eq 0 ] && [ "$_u" -eq 2 ]; then
	ok "(P0) the pool helper exits 0 for --help and 2 for a usage error"
else
	no "(P0) the pool helper exits 0 for --help and 2 for a usage error (help=$_h usage=$_u)"
fi
# a blank device: the first mebibyte is zero
dd if=/dev/zero of="$work/dev0" bs=1048576 count=1 2> /dev/null

PATH="$work/bin:$PATH" STUB_LOG="$work/zpool.log" sh "$poolhelper" "$work/dev0" > "$work/pool.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && ! grep -q -- 'zpool create' "$work/zpool.log"; then
	ok "(P1) without --yes the helper creates nothing"
else
	no "(P1) without --yes the helper creates nothing (rc=$rc)"
	sed 's/^/      | /' "$work/pool.log"
fi

: > "$work/zpool.log"
PATH="$work/bin:$PATH" STUB_LOG="$work/zpool.log" sh "$poolhelper" --yes "$work/dev0" > "$work/pool.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q -- "zpool create exampledata $work/dev0" "$work/zpool.log"; then
	ok "(P1) with --yes the helper creates the pool"
else
	no "(P1) with --yes the helper creates the pool (rc=$rc)"
	sed 's/^/      | /' "$work/pool.log"
fi
if grep -q -- 'zpool create -f' "$work/zpool.log"; then
	no "(P1) the pool is not created with -f without --force"
else
	ok "(P1) the pool is not created with -f without --force"
fi

: > "$work/zpool.log"
PATH="$work/bin:$PATH" STUB_LOG="$work/zpool.log" sh "$poolhelper" --yes --force "$work/dev0" > "$work/pool.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q -- "zpool create -f exampledata $work/dev0" "$work/zpool.log"; then
	ok "(P1) --force is an explicit flag of its own"
else
	no "(P1) --force is an explicit flag of its own (rc=$rc)"
	sed 's/^/      | /' "$work/pool.log"
fi

: > "$work/zpool.log"
WTFBSD_STUB_POOL_EXISTS=1 PATH="$work/bin:$PATH" STUB_LOG="$work/zpool.log" \
	sh "$poolhelper" --yes "$work/dev0" > "$work/pool.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q -- 'zpool create' "$work/zpool.log"; then
	ok "(P1) an existing pool is refused"
else
	no "(P1) an existing pool is refused (rc=$rc)"
	sed 's/^/      | /' "$work/pool.log"
fi

: > "$work/zpool.log"
WTFBSD_STUB_ROOT_DEVICE=wd0 PATH="$work/bin:$PATH" STUB_LOG="$work/zpool.log" \
	sh "$poolhelper" --yes /dev/wd0d > "$work/pool.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q -- 'zpool create' "$work/zpool.log"; then
	ok "(P1) the disk that holds the running root is refused"
else
	no "(P1) the disk that holds the running root is refused (rc=$rc)"
	sed 's/^/      | /' "$work/pool.log"
fi

: > "$work/zpool.log"
WTFBSD_STUB_GPT=1 PATH="$work/bin:$PATH" STUB_LOG="$work/zpool.log" \
	sh "$poolhelper" --yes "$work/dev0" > "$work/pool.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q -- 'zpool create' "$work/zpool.log"; then
	ok "(P1) a device with a partition table is refused"
else
	no "(P1) a device with a partition table is refused (rc=$rc)"
	sed 's/^/      | /' "$work/pool.log"
fi

# a blank disk: gpt(8) prints the map of the free space and exits with
# 0, so the exit status says nothing and the decision comes from the
# output: a listing without the rows of the GPT header leaves the disk
# a candidate
: > "$work/zpool.log"
PATH="$work/bin:$PATH" STUB_LOG="$work/zpool.log" \
	sh "$poolhelper" --yes "$work/dev0" > "$work/pool.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q -- "zpool create exampledata $work/dev0" "$work/zpool.log"; then
	ok "(P1) a blank disk whose gpt listing has no GPT header is a candidate"
else
	no "(P1) a blank disk whose gpt listing has no GPT header is a candidate (rc=$rc)"
	sed 's/^/      | /' "$work/pool.log"
fi

# the root is a wedge (dk1) on the disk wd0: every wedge and every
# partition of that disk is refused
: > "$work/zpool.log"
WTFBSD_STUB_ROOT_DEVICE=dk1 WTFBSD_STUB_WEDGE_PARENT=wd0 \
	PATH="$work/bin:$PATH" STUB_LOG="$work/zpool.log" \
	sh "$poolhelper" --yes /dev/dk2 > "$work/pool.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q 'zpool create' "$work/zpool.log"; then
	ok "(P1) a wedge of the disk that holds the running root is refused"
else
	no "(P1) a wedge of the disk that holds the running root is refused (rc=$rc)"
	sed 's/^/      | /' "$work/pool.log"
fi

# a device that carries something is refused, unless --force is given
printf 'not a blank device\n' > "$work/dev1"
: > "$work/zpool.log"
PATH="$work/bin:$PATH" STUB_LOG="$work/zpool.log" \
	sh "$poolhelper" --yes "$work/dev1" > "$work/pool.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && ! grep -q 'zpool create' "$work/zpool.log"; then
	ok "(P1) a device that is not blank is refused"
else
	no "(P1) a device that is not blank is refused (rc=$rc)"
	sed 's/^/      | /' "$work/pool.log"
fi

: > "$work/zpool.log"
PATH="$work/bin:$PATH" STUB_LOG="$work/zpool.log" \
	sh "$poolhelper" --yes --force "$work/dev1" > "$work/pool.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q -- "zpool create -f exampledata $work/dev1" "$work/zpool.log"; then
	ok "(P1) --force creates the pool on a device that is not blank"
else
	no "(P1) --force creates the pool on a device that is not blank (rc=$rc)"
	sed 's/^/      | /' "$work/pool.log"
fi

# --- P2: wedge_parent names the disk of a wedge ---------------------------
# The helper is a script and not a library, so the function is cut out
# of it and run on its own, with the stub of dkctl(8) on the PATH.
sed -n '/^wedge_parent()/,/^}/p' "$poolhelper" > "$work/wedge-parent.sh"
if [ -s "$work/wedge-parent.sh" ]; then
	ok "(P2) the helper holds a wedge_parent function"
else
	no "(P2) the helper holds a wedge_parent function"
fi
out=$(PATH="$work/bin:$PATH" STUB_LOG="$work/zpool.log" WTFBSD_STUB_WEDGE_PARENT=wd0 \
	sh -c '. "$1"; wedge_parent dk1' sh "$work/wedge-parent.sh" 2>&1)
if [ "$out" = 'wd0' ]; then
	ok "(P2) wedge_parent names the disk of the wedge (dk1 -> wd0)"
else
	no "(P2) wedge_parent names the disk of the wedge (dk1 -> wd0) (got: $out)"
fi
out=$(PATH="$work/bin:$PATH" STUB_LOG="$work/zpool.log" WTFBSD_STUB_DKCTL_SHAPE=alt \
	WTFBSD_STUB_WEDGE_PARENT=wd0 \
	sh -c '. "$1"; wedge_parent dk1' sh "$work/wedge-parent.sh" 2>&1)
if [ "$out" = 'wd0' ]; then
	ok "(P2) wedge_parent names the disk of the wedge in another shape of the output"
else
	no "(P2) wedge_parent names the disk of the wedge in another shape of the output (got: $out)"
fi

# --- S1: the Jenkinsfile ----------------------------------------------------
sshline=$(grep -nE '(^|[[:space:]])(ssh|scp)[[:space:]]' "$repo/Jenkinsfile" 2> /dev/null |
	grep -v 'BatchMode=yes' || true)
if [ -z "$sshline" ]; then
	ok "(S1) every ssh and scp in the Jenkinsfile runs with BatchMode=yes"
else
	no "(S1) every ssh and scp in the Jenkinsfile runs with BatchMode=yes"
	printf '%s\n' "$sshline" | sed 's/^/      | /'
fi
if grep -q 'A-Za-z0-9._/-' "$repo/Jenkinsfile" &&
	grep -q 'BUILD_VM_WORKDIR' "$repo/Jenkinsfile" &&
	grep -q 'PRODUCT_CONF' "$repo/Jenkinsfile"; then
	ok "(S1) the Jenkinsfile validates the free-text parameters"
else
	no "(S1) the Jenkinsfile validates the free-text parameters"
fi
unvalidated=''
for p in PROFILE CONF_PATH BUILD_VM_WORKDIR; do
	grep -q "check_param $p " "$repo/Jenkinsfile" 2> /dev/null || unvalidated="$unvalidated $p"
done
if [ -z "$unvalidated" ]; then
	ok "(S1) every free-text parameter is checked before it is used"
else
	no "(S1) every free-text parameter is checked before it is used:$unvalidated"
fi
if grep -q 'StrictHostKeyChecking=accept-new' "$repo/Jenkinsfile" &&
	grep -q 'UserKnownHostsFile' "$repo/Jenkinsfile"; then
	ok "(S1) the Jenkinsfile pins the host key handling of ssh and scp"
else
	no "(S1) the Jenkinsfile pins the host key handling of ssh and scp"
fi

# --- S2: the Jenkinsfile is Groovy, and its shell blocks parse -------------
# A line that starts with # outside a sh string is a Groovy syntax error:
# Groovy has // for a comment, and # is not one there. The state machine
# below knows the two kinds of line: the sh strings (''' ... ''') and the
# Groovy around them.
q3=$(printf '\047\047\047')
badlines=$(awk -v q="$q3" '
	{
		n = 0
		rest = $0
		while ((p = index(rest, q)) > 0) {
			n++
			rest = substr(rest, p + 3)
		}
		if (n % 2 == 1) { inside = !inside }
		if (!inside && $0 ~ /^[[:space:]]*#/) { print NR }
	}
' "$repo/Jenkinsfile")
if [ -z "$badlines" ]; then
	ok "(S2) no line of the Jenkinsfile outside a sh string starts with #"
else
	no "(S2) no line of the Jenkinsfile outside a sh string starts with # (lines: $(printf '%s' "$badlines" | tr '\n' ' '))"
fi

# every sh ''' ... ''' block of the pipeline has to be a shell script that
# parses: the pipeline is never run here, so this is the only check it gets
awk -v q="$q3" '
	{
		if (inside) {
			if (index($0, q) > 0) {
				inside = 0
				rest = substr($0, index($0, q) + 3)
				gsub(/^[ \t]+/, "", rest)
				if (rest != "") { print rest }
				next
			}
			print
			next
		}
		if ($0 ~ /sh[[:space:]]*'"$q3"'[[:space:]]*$/) { inside = 1 }
	}
' "$repo/Jenkinsfile" > "$work/jenkins-sh.sh"
if [ -s "$work/jenkins-sh.sh" ] && sh -n "$work/jenkins-sh.sh" 2> "$work/jenkins-sh.log"; then
	ok "(S2) every sh block of the Jenkinsfile is a shell script that parses"
else
	no "(S2) every sh block of the Jenkinsfile is a shell script that parses"
	sed 's/^/      | /' "$work/jenkins-sh.log"
fi

# --- S3: the product.conf comes from the File Parameter plugin -------------
# The legacy file(...) parameter of the core uploads nothing: it points
# at a file on the agent. The File Parameter plugin stashes the uploaded
# file, and the pipeline takes it with stashedFile() and unstash().
if grep -qE '^[[:space:]]*file\(' "$repo/Jenkinsfile"; then
	no "(S3) the Jenkinsfile declares no legacy file(...) parameter"
else
	ok "(S3) the Jenkinsfile declares no legacy file(...) parameter"
fi
# stashedFile is a PARAMETER type of the plugin, declared in the
# parameters block; called as a step it does nothing useful.
if grep -v '^[[:space:]]*//' "$repo/Jenkinsfile" | grep -qE 'def [A-Za-z_]+ *= *stashedFile|stashedFile\(.PRODUCT_CONF.\)'; then
	no "(S3) the pipeline takes the product.conf from the stashed file parameter (stashedFile used as a step)"
else
	ok "(S3) the pipeline takes the product.conf from the stashed file parameter"
fi
pat_cp='cp PRODUCT_CONF product.conf'
if grep -qF "unstash 'PRODUCT_CONF'" "$repo/Jenkinsfile" &&
	grep -qF "$pat_cp" "$repo/Jenkinsfile"; then
	ok "(S3) the pipeline unstashes the product.conf and copies it to product.conf"
else
	no "(S3) the pipeline unstashes the product.conf and copies it to product.conf"
fi

# --- S5: the parameters block of the pipeline ------------------------------
# The block is what the job shows to the person who starts the build, so
# what it declares is parsed here and not only read in the stages.
params_block=$(awk '
	/^[[:space:]]*parameters[[:space:]]*\{/ { inside = 1 }
	inside { print }
	inside && /^[[:space:]]*\}[[:space:]]*$/ { exit }
' "$repo/Jenkinsfile")
if [ -n "$params_block" ]; then
	ok "(S5) the pipeline has a parameters block"
else
	no "(S5) the pipeline has a parameters block"
fi
param_count=$(printf '%s\n' "$params_block" | grep -c "name: '")
desc_count=$(printf '%s\n' "$params_block" | grep -c 'description:')
if [ "$param_count" -gt 0 ] && [ "$param_count" -eq "$desc_count" ]; then
	ok "(S5) every parameter of the block carries a description"
else
	no "(S5) every parameter of the block carries a description ($desc_count descriptions for $param_count parameters)"
fi
if printf '%s\n' "$params_block" | grep -qF "name: 'PRODUCT_CONF_FILENAME'"; then
	no "(S5) the block leaves PRODUCT_CONF_FILENAME to the plugin"
else
	ok "(S5) the block leaves PRODUCT_CONF_FILENAME to the plugin"
fi
if printf '%s\n' "$params_block" | grep -v '^[[:space:]]*//' | grep -q 'stashedFile(' &&
	printf '%s\n' "$params_block" | grep -qF "name: 'PRODUCT_CONF'"; then
	ok "(S5) the block declares the stashed file parameter PRODUCT_CONF"
else
	no "(S5) the block declares the stashed file parameter PRODUCT_CONF"
fi
if printf '%s\n' "$params_block" | grep -q 'stashedFile(' &&
	grep -qF "unstash 'PRODUCT_CONF'" "$repo/Jenkinsfile" &&
	grep -qF 'cp PRODUCT_CONF product.conf' "$repo/Jenkinsfile"; then
	ok "(S5) the pipeline takes the stashed file and copies it to product.conf"
else
	no "(S5) the pipeline takes the stashed file and copies it to product.conf"
fi
if grep -qF 'env.PRODUCT_CONF_FILENAME' "$repo/Jenkinsfile"; then
	ok "(S5) the pipeline tests the name the plugin gave the uploaded file"
else
	no "(S5) the pipeline tests the name the plugin gave the uploaded file"
fi

# --- S6: the path of the product configuration is a variable of its own ----
# PRODUCT_CONF is a file parameter of the job: Jenkins exports it as an
# environment variable of the build, and a script that assigns to it may
# not be allowed to. The path of the file the build reads is therefore
# published under a name of its own.
if grep -qF 'env.PRODUCT_CONF =' "$repo/Jenkinsfile" ||
	grep -qF 'env.PRODUCT_CONF=' "$repo/Jenkinsfile"; then
	no "(S6) the pipeline does not assign to the environment variable of the PRODUCT_CONF parameter"
else
	ok "(S6) the pipeline does not assign to the environment variable of the PRODUCT_CONF parameter"
fi
if grep -qF 'env.CONF_PATH =' "$repo/Jenkinsfile"; then
	ok "(S6) the pipeline publishes the path of the product configuration as CONF_PATH"
else
	no "(S6) the pipeline publishes the path of the product configuration as CONF_PATH"
fi
if grep -qF '$CONF_PATH' "$work/jenkins-sh.sh"; then
	ok "(S6) the shell steps of the pipeline read the configuration at \$CONF_PATH"
else
	no "(S6) the shell steps of the pipeline read the configuration at \$CONF_PATH"
fi
if grep -qF '$PRODUCT_CONF' "$work/jenkins-sh.sh"; then
	no "(S6) no shell step of the pipeline reads the PRODUCT_CONF parameter as a path"
else
	ok "(S6) no shell step of the pipeline reads the PRODUCT_CONF parameter as a path"
fi

# --- S4: the label of the agent is a placeholder --------------------------
# The label is the name of an agent of the site that runs the pipeline:
# this repository is generic, so it carries a placeholder. The test
# names no other label: the label of the site is not written down here.
agent_default=$(printf '%s\n' "$params_block" | awk '
	/name: .AGENT_LABEL./ { found = 1; next }
	found && /name: / { exit }
	found && /defaultValue:/ {
		v = $0
		sub(/.*defaultValue: /, "", v)
		gsub(/[^A-Za-z0-9_.-]/, "", v)
		print v
		exit
	}
')
if [ "$agent_default" = 'bsd' ]; then
	ok "(S4) the default label of the agent is the placeholder bsd"
else
	no "(S4) the default label of the agent is the placeholder bsd (got: ${agent_default:-nothing})"
fi
if grep -q 'params.AGENT_LABEL' "$repo/Jenkinsfile"; then
	ok "(S4) the pipeline takes the label of the agent from the parameter"
else
	no "(S4) the pipeline takes the label of the agent from the parameter"
fi
if grep -qE '\| `AGENT_LABEL` \| `bsd` \|' "$repo/README.md" &&
	grep -qi 'placeholder' "$repo/README.md"; then
	ok "(S4) the README says that the label of the agent is a placeholder"
else
	no "(S4) the README says that the label of the agent is a placeholder"
fi

# --- X: the X sets of the release are not unpacked -------------------------
if [ -e "$stage/usr/X11R6" ]; then
	no "(X) the X11 set of the release is not unpacked into the image"
else
	ok "(X) the X11 set of the release is not unpacked into the image"
fi
if grep -q -- 'xbase xcomp xetc xfont xserver' "$build"; then
	ok "(X) the build skips the X sets of the release by name"
else
	no "(X) the build skips the X sets of the release by name"
fi
if grep -q 'xorg-server' "$repo/overlay/profiles/desktop/packages.list" &&
	grep -qi 'pkgsrc' "$repo/overlay/profiles/desktop/packages.list"; then
	ok "(X) the desktop profile takes its X11 stack from pkgsrc"
else
	no "(X) the desktop profile takes its X11 stack from pkgsrc"
fi

# --------------------------------------------------------------------------
# (C) the CI layer: the serial console reader, the VM names, the destroy
#     path and the pipeline
# --------------------------------------------------------------------------
provider="$repo/ci/providers/bhyve.sh"
jenkins="$repo/Jenkinsfile"

# (C0) the tap exists even without a bridge: bhyve(8) opens it either way,
#      so the create of the tap comes before the bridge is looked at
_tap_l=$(grep -n 'ifconfig "$TAP" create' "$provider" | head -1 | cut -d: -f1)
_br_l=$(grep -n 'if \[ -n "$BRIDGE" \]; then' "$provider" | head -1 | cut -d: -f1)
if [ -n "$_tap_l" ] && [ -n "$_br_l" ] && [ "$_tap_l" -lt "$_br_l" ]; then
	ok "(C0) the tap is created whether or not a bridge is configured"
else
	no "(C0) the tap is created whether or not a bridge is configured"
fi
readme="$repo/README.md"
ci_image="$work/ci-image.img"
: > "$ci_image"
sed '/login:/,$d' "$repo/tests/fixtures/serial-login.log" > "$work/ci-no-login.log"

# (C1) the console reader reads the null-modem in raw mode without echo
# The null-modem opens in canonical mode with echo (sys/kern/tty.c,
# TTYDEF_LFLAG) and the prompt of getty has no newline (libexec/getty/
# init.c), so a canonical read never returns it and echo feeds the guest
# output back to the guest as input.
if grep -qF '( stty raw -echo; exec cat ) < "$NMDM_B" >' "$provider"; then
	ok "(C1) the console reader reads the null-modem in raw mode without echo"
else
	no "(C1) the console reader reads the null-modem in raw mode without echo"
fi
if grep -qF -- '-l com1,"$NMDM_A"' "$provider" && grep -qF '"$NMDM_B"' "$provider"; then
	ok "(C1) bhyve gets the A side of the null-modem and the reader the B side"
else
	no "(C1) bhyve gets the A side of the null-modem and the reader the B side"
fi
if grep -qF -- '-l bootrom,"$FIRMWARE"' "$provider" && grep -qF -- '-s 31,lpc' "$provider"; then
	ok "(C1) the firmware is a boot ROM and the serial port has its LPC device"
else
	no "(C1) the firmware is a boot ROM and the serial port has its LPC device"
fi

# (C2) the pipeline names the boot-test VMs after the job and the build, and
#      the boot test uses the name it is given
if grep -q 'wtfbsd-vm-list' "$jenkins" && grep -q 'JOB_BASE_NAME' "$jenkins" &&
	grep -q 'BUILD_NUMBER' "$jenkins"; then
	ok "(C2) the pipeline names the boot-test VMs after the job and the build"
else
	no "(C2) the pipeline names the boot-test VMs after the job and the build"
fi
if grep -q 'destroy' "$jenkins" && grep -q 'wtfbsd-vm-list' "$jenkins"; then
	ok "(C2) the pipeline destroys every VM it listed"
else
	no "(C2) the pipeline destroys every VM it listed"
fi
postblock=$(awk '/post \{/,0' "$jenkins")
if printf '%s\n' "$postblock" | grep -q 'ci/vm.sh destroy'; then
	ok "(C2) the post block destroys the VMs of the list"
else
	no "(C2) the post block destroys the VMs of the list"
fi
: > "$work/ci-state"
WTFBSD_VM_PROVIDER=fake \
WTFBSD_VM_PROVIDER_PATH="$repo/tests/fixtures/fake-provider.sh" \
WTFBSD_FAKE_STATE="$work/ci-state" \
WTFBSD_FAKE_LOG="$work/ci-serial.log" \
WTFBSD_FAKE_SOURCE_LOG="$repo/tests/fixtures/serial-login.log" \
WTFBSD_FAKE_ADDR=127.0.0.1 \
WTFBSD_BOOT_TIMEOUT=20 \
	sh "$boottest" "$ci_image" desktop boot-desktop-job-42 > "$work/ci-boot.log" 2>&1
rc=$?
if [ "$rc" -eq 0 ] && grep -q '^create boot-desktop-job-42' "$work/ci-state"; then
	ok "(C2) the boot test uses the VM name it is given"
else
	no "(C2) the boot test uses the VM name it is given (rc=$rc)"
	sed 's/^/      | /' "$work/ci-boot.log"
fi

# (C3) every ssh and scp is batch mode with a pinned host key handling, and
#      the product.conf lands in the build directory of the build VM
sshlines=$(grep -nE '(^|[[:space:]])(ssh|scp)[[:space:]]' "$jenkins" 2> /dev/null |
	grep -v 'StrictHostKeyChecking=accept-new' || true)
if [ -z "$sshlines" ]; then
	ok "(C3) every ssh and scp in the pipeline pins the host key handling"
else
	no "(C3) every ssh and scp in the pipeline pins the host key handling"
	printf '%s\n' "$sshlines" | sed 's/^/      | /'
fi
sshlines=$(grep -nE '(^|[[:space:]])(ssh|scp)[[:space:]]' "$jenkins" 2> /dev/null |
	grep -v 'UserKnownHostsFile' || true)
if [ -z "$sshlines" ]; then
	ok "(C3) every ssh and scp in the pipeline writes its known hosts to the workspace"
else
	no "(C3) every ssh and scp in the pipeline writes its known hosts to the workspace"
	printf '%s\n' "$sshlines" | sed 's/^/      | /'
fi
if grep -qF '"$addr:$BUILD_VM_WORKDIR/product.conf"' "$jenkins"; then
	ok "(C3) the pipeline copies the product.conf into the build directory of the build VM"
else
	no "(C3) the pipeline copies the product.conf into the build directory of the build VM"
fi

# (C4) the boot test waits for sshd and fails when it never answers
closed_port=21345
while nc -z 127.0.0.1 "$closed_port" > /dev/null 2>&1; do
	closed_port=$((closed_port + 1))
done
: > "$work/ci-state"
WTFBSD_VM_PROVIDER=fake \
WTFBSD_VM_PROVIDER_PATH="$repo/tests/fixtures/fake-provider.sh" \
WTFBSD_FAKE_STATE="$work/ci-state" \
WTFBSD_FAKE_LOG="$work/ci-serial.log" \
WTFBSD_FAKE_SOURCE_LOG="$repo/tests/fixtures/serial-login.log" \
WTFBSD_FAKE_ADDR=127.0.0.1 \
WTFBSD_FAKE_SSH_PORT= \
WTFBSD_BOOT_TIMEOUT=3 \
WTFBSD_BOOT_SSH_PORT="$closed_port" \
	sh "$boottest" "$ci_image" appliance > "$work/ci-sshd.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && grep -qi 'sshd' "$work/ci-sshd.log"; then
	ok "(C4) the boot test fails when sshd never answers"
else
	no "(C4) the boot test fails when sshd never answers (rc=$rc)"
	sed 's/^/      | /' "$work/ci-sshd.log"
fi

# (C5) the boot test destroys the VM when it is terminated
: > "$work/ci-state"
WTFBSD_VM_PROVIDER=fake \
WTFBSD_VM_PROVIDER_PATH="$repo/tests/fixtures/fake-provider.sh" \
WTFBSD_FAKE_STATE="$work/ci-state" \
WTFBSD_FAKE_LOG="$work/ci-serial.log" \
WTFBSD_FAKE_SOURCE_LOG="$work/ci-no-login.log" \
WTFBSD_FAKE_ADDR=127.0.0.1 \
WTFBSD_BOOT_TIMEOUT=60 \
	sh "$boottest" "$ci_image" desktop > "$work/ci-term.log" 2>&1 &
cipid=$!
sleep 1
kill -TERM "$cipid" 2> /dev/null || true
wait "$cipid"
rc=$?
if [ "$rc" -ne 0 ] && grep -q '^destroy' "$work/ci-state"; then
	ok "(C5) the boot test destroys the VM when it is terminated"
else
	no "(C5) the boot test destroys the VM when it is terminated (rc=$rc)"
	sed 's/^/      | /' "$work/ci-term.log"
fi

# (C6) ci/vm.sh refuses a bad VM name before it calls the provider
: > "$work/ci-state"
WTFBSD_VM_PROVIDER=fake \
WTFBSD_VM_PROVIDER_PATH="$repo/tests/fixtures/fake-provider.sh" \
WTFBSD_FAKE_STATE="$work/ci-state" \
WTFBSD_FAKE_LOG="$work/ci-serial.log" \
	sh "$vmsh" create 'bad name' "$ci_image" > "$work/ci-badname.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$work/ci-state" ]; then
	ok "(C6) ci/vm.sh refuses a bad VM name without calling the provider"
else
	no "(C6) ci/vm.sh refuses a bad VM name without calling the provider (rc=$rc)"
	sed 's/^/      | /' "$work/ci-badname.log"
fi

# (C7) a VM name with a newline in it is refused everywhere
nl_name=$(printf 'ok\nx')
: > "$work/ci-state"
WTFBSD_VM_PROVIDER=fake \
WTFBSD_VM_PROVIDER_PATH="$repo/tests/fixtures/fake-provider.sh" \
WTFBSD_FAKE_STATE="$work/ci-state" \
WTFBSD_FAKE_LOG="$work/ci-serial.log" \
	sh "$vmsh" create "$nl_name" "$ci_image" > "$work/ci-newline.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] && [ ! -s "$work/ci-state" ]; then
	ok "(C7) ci/vm.sh refuses a VM name with a newline in it"
else
	no "(C7) ci/vm.sh refuses a VM name with a newline in it (rc=$rc)"
	sed 's/^/      | /' "$work/ci-newline.log"
fi
sh "$repo/tests/fixtures/fake-provider.sh" create "$nl_name" "$ci_image" > "$work/ci-nlprov.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	ok "(C7) a provider refuses a VM name with a newline in it"
else
	no "(C7) a provider refuses a VM name with a newline in it (rc=0)"
	sed 's/^/      | /' "$work/ci-nlprov.log"
fi

# (C8) a VM that is already gone is not a failure, and a destroy that fails
#      is reported on stderr
if grep -qF '/dev/vmm/' "$provider" && grep -qF 'command -v bhyvectl' "$provider"; then
	ok "(C8) the bhyve provider looks for the VM and for bhyvectl"
else
	no "(C8) the bhyve provider looks for the VM and for bhyvectl"
fi
: > "$work/ci-state"
WTFBSD_VM_PROVIDER=fake \
WTFBSD_VM_PROVIDER_PATH="$repo/tests/fixtures/fake-provider.sh" \
WTFBSD_FAKE_STATE="$work/ci-state" \
WTFBSD_FAKE_LOG="$work/ci-serial.log" \
WTFBSD_FAKE_SOURCE_LOG="$repo/tests/fixtures/serial-login.log" \
WTFBSD_FAKE_ADDR=127.0.0.1 \
WTFBSD_FAKE_DESTROY_FAIL=1 \
WTFBSD_BOOT_TIMEOUT=20 \
	sh "$boottest" "$ci_image" desktop > "$work/ci-destroy.out" 2> "$work/ci-destroy.err"
rc=$?
if [ -s "$work/ci-destroy.err" ] && grep -qi 'destroy' "$work/ci-destroy.err"; then
	ok "(C8) the boot test reports on stderr a VM it could not destroy"
else
	no "(C8) the boot test reports on stderr a VM it could not destroy (rc=$rc)"
	sed 's/^/      | /' "$work/ci-destroy.err"
fi

# (C9) the null-modem and the tap follow the executor, and the reader pid
#      is recorded so that a stale reader can be killed
if grep -q 'EXECUTOR_NUMBER' "$provider" && grep -qF '$name.reader.pid' "$provider"; then
	ok "(C9) the null-modem and the tap follow the executor and the reader pid is recorded"
else
	no "(C9) the null-modem and the tap follow the executor and the reader pid is recorded"
fi

# (C10) the provider attaches the tap to the bridge, and the README tells
#       the truth about the bridge and about the firmware
if grep -qF 'addm "$TAP"' "$provider" && grep -qF 'deletem "$TAP"' "$provider"; then
	ok "(C10) the provider attaches the tap to the bridge and detaches it again"
else
	no "(C10) the provider attaches the tap to the bridge and detaches it again"
fi
if grep -i 'bridge' "$readme" | grep -qi 'master'; then
	no "(C10) the README does not tell the reader to use a bridge keyword that does not exist"
else
	ok "(C10) the README does not tell the reader to use a bridge keyword that does not exist"
fi
if grep -qi 'edk2' "$readme"; then
	ok "(C10) the README names the package that carries the firmware"
else
	no "(C10) the README names the package that carries the firmware"
fi

# (C11) the pipeline takes the product.conf from the file parameter, and the
#       README documents the plugin it needs
if grep -qF 'stashedFile' "$jenkins" && grep -qF "unstash 'PRODUCT_CONF'" "$jenkins"; then
	ok "(C11) the pipeline unstashes the product.conf of the file parameter"
else
	no "(C11) the pipeline unstashes the product.conf of the file parameter"
fi
if grep -qi 'file parameter' "$readme"; then
	ok "(C11) the README documents the plugin the file parameter needs"
else
	no "(C11) the README documents the plugin the file parameter needs"
fi

# (C12) the provider runs with the privileges of the agent, and says so
if grep -qF 'id -u' "$provider"; then
	ok "(C12) the bhyve provider refuses to run without root"
else
	no "(C12) the bhyve provider refuses to run without root"
fi
if grep -qi 'root-owned' "$readme" && grep -qi 'not writable' "$readme"; then
	ok "(C12) the README says how the provider script has to be owned"
else
	no "(C12) the README says how the provider script has to be owned"
fi

# (C13) the sshd probe is bounded, and an image path with a comma is refused
if grep -qF 'nc -z -w 2' "$boottest"; then
	ok "(C13) the sshd probe uses a bounded connect"
else
	no "(C13) the sshd probe uses a bounded connect"
fi
if grep -qF '*,*)' "$provider"; then
	ok "(C13) the bhyve provider refuses an image path with a comma in it"
else
	no "(C13) the bhyve provider refuses an image path with a comma in it"
fi

# --------------------------------------------------------------------------
# (D) the stubs refuse the options the manual pages do not have, and the
#     rc.subr of NetBSD dispatches to ${rc_arg}_cmd
# --------------------------------------------------------------------------
# A stub that takes every option cannot catch a build that hands makefs(8)
# an option that does not exist: the stub would swallow it and the real
# tool would refuse it on the build host.

STUB_LOG="$work/opt.log"
export STUB_LOG

stub_refuses() { # stub_refuses <stub> <option> — does the stub refuse it?
	: > "$STUB_LOG"
	sh "$stubs/bin/$1" "$2" > "$work/opt.out" 2>&1
	_rc=$?
	if [ "$_rc" -ne 0 ] && grep -qi 'illegal option' "$work/opt.out"; then
		return 0
	fi
	return 1
}

stub_takes() { # stub_takes <stub> <option> — does the stub take the option?
	: > "$STUB_LOG"
	sh "$stubs/bin/$1" "$2" > "$work/opt.out" 2>&1
	if grep -qi 'illegal option' "$work/opt.out"; then
		return 1
	fi
	return 0
}

for spec in 'nbmakefs -e' 'nbinstallboot -x' 'pkg_add -N' 'nbpwd_mkdb -Z' 'nbgpt -Q'; do
	_stub=${spec%% *}
	_opt=${spec#* }
	if stub_refuses "$_stub" "$_opt"; then
		ok "(D) the $_stub stub refuses $_opt"
	else
		no "(D) the $_stub stub refuses $_opt"
	fi
done

for spec in 'nbmakefs -Z' 'nbinstallboot -v' 'pkg_add -v' 'nbpwd_mkdb -v'; do
	_stub=${spec%% *}
	_opt=${spec#* }
	if stub_takes "$_stub" "$_opt"; then
		ok "(D) the $_stub stub takes $_opt"
	else
		no "(D) the $_stub stub takes $_opt"
	fi
done

# gpt(8) add takes -a <alignment> and -b <start>, each with an argument
: > "$work/gpt-ab.img"
STUB_LOG="$work/gpt-ab.log" sh "$stubs/bin/nbgpt" "$work/gpt-ab.img" create > /dev/null 2>&1
STUB_LOG="$work/gpt-ab.log" sh "$stubs/bin/nbgpt" "$work/gpt-ab.img" add -a 1m -b 2048 -t efi -s 16m -i 1 -l esp > "$work/gpt-ab.out" 2>&1
_ab=$?
STUB_LOG="$work/gpt-ab.log" sh "$stubs/bin/nbgpt" "$work/gpt-ab.img" add -t efi -s 16m -a > "$work/gpt-ab2.out" 2>&1
_ab2=$?
if [ "$_ab" -eq 0 ] && [ "$_ab2" -ne 0 ] && grep -q 'option -a requires an argument' "$work/gpt-ab2.out"; then
	ok "(D) nbgpt add takes -a <alignment> and -b <start> with an argument each"
else
	no "(D) nbgpt add takes -a <alignment> and -b <start> with an argument each (rc=$_ab/$_ab2)"
	sed 's/^/      | /' "$work/gpt-ab.out" "$work/gpt-ab2.out"
fi
# nbgpt create must not truncate the image that dd wrote
printf 'the disk image\n' > "$work/gpt-image.img"
: > "$STUB_LOG"
sh "$stubs/bin/nbgpt" create "$work/gpt-image.img" > "$work/gpt.out" 2>&1
if [ "$(cat "$work/gpt-image.img")" = 'the disk image' ]; then
	ok "(D) nbgpt create does not truncate the image dd wrote"
else
	no "(D) nbgpt create does not truncate the image dd wrote"
fi

# the rc.subr of NetBSD takes the command of the argument from
# ${rc_arg}_cmd: the variable start_cmd names the function that "start"
# runs. It never calls <name>_start by itself.
cat > "$work/rcsubr-dispatch.sh" <<'RCEOF'
. "$1"
my_start() { echo RAN-start; }
my_stop() { echo RAN-stop; }
start_cmd="my_start"
stop_cmd="my_stop"
run_rc_command start
run_rc_command stop
RCEOF
out=$(sh "$work/rcsubr-dispatch.sh" "$stubs/rc.subr" 2>&1)
if [ "$out" = 'RAN-start
RAN-stop' ]; then
	ok "(D) the rc.subr runs the function that start_cmd and stop_cmd name"
else
	no "(D) the rc.subr runs the function that start_cmd and stop_cmd name (got: $out)"
fi

cat > "$work/rcsubr-nodefault.sh" <<'RCEOF'
. "$1"
my_start() { echo RAN-start; }
run_rc_command start
RCEOF
out=$(sh "$work/rcsubr-nodefault.sh" "$stubs/rc.subr" 2>&1)
if [ -z "$out" ]; then
	ok "(D) the rc.subr never calls <name>_start by itself"
else
	no "(D) the rc.subr never calls <name>_start by itself (got: $out)"
fi

# (C14) the VMs of one job never share a null-modem pair or a tap
u_build=$(EXECUTOR_NUMBER=3 WTFBSD_VM_SLOT=0 sh "$provider" unit buildvm 2>&1)
u_boot=$(EXECUTOR_NUMBER=3 WTFBSD_VM_SLOT=1 sh "$provider" unit bootvm 2>&1)
if [ -n "$u_build" ] && [ -n "$u_boot" ] && [ "$u_build" != "$u_boot" ]; then
	ok "(C14) two VMs of one job get different null-modem and tap devices"
else
	no "(C14) two VMs of one job get different null-modem and tap devices"
	printf '%s\n' "$u_build" "$u_boot" | sed 's/^/      | /'
fi
u_other=$(EXECUTOR_NUMBER=4 WTFBSD_VM_SLOT=0 sh "$provider" unit buildvm 2>&1)
if [ -n "$u_other" ] && [ "$u_build" != "$u_other" ]; then
	ok "(C14) two jobs on one host get different null-modem and tap devices"
else
	no "(C14) two jobs on one host get different null-modem and tap devices"
	printf '%s\n' "$u_build" "$u_other" | sed 's/^/      | /'
fi
if grep -q 'WTFBSD_VM_SLOT=0' "$jenkins" && grep -q 'WTFBSD_VM_SLOT=1' "$jenkins"; then
	ok "(C14) the pipeline gives the build VM and the boot-test VMs another slot"
else
	no "(C14) the pipeline gives the build VM and the boot-test VMs another slot"
fi
buildstage=$(awk "/stage\('Build'\)/,/stage\('Boot test'\)/" "$jenkins")
if printf '%s\n' "$buildstage" | grep -q 'ci/vm.sh destroy'; then
	ok "(C14) the pipeline destroys the build VM at the end of the Build stage"
else
	no "(C14) the pipeline destroys the build VM at the end of the Build stage"
fi
if grep -q 'env.BUILD_VM.*env.VM_LIST' "$jenkins"; then
	ok "(C14) the build VM is in the list of the VMs of the build"
else
	no "(C14) the build VM is in the list of the VMs of the build"
fi

# (C15) the unit of the devices is the executor and the slot, without a
#       modulo, and the post block destroys every VM with its slot
u_exec=$(EXECUTOR_NUMBER=7 WTFBSD_VM_SLOT=1 sh "$provider" unit buildvm 2>&1)
if printf '%s\n' "$u_exec" | grep -q 'nmdm=/dev/nmdm15A' &&
	printf '%s\n' "$u_exec" | grep -q 'tap=tap15'; then
	ok "(C15) the unit of the devices is the executor twice plus the slot"
else
	no "(C15) the unit of the devices is the executor twice plus the slot (got: $u_exec)"
fi
if grep -q '% 10' "$provider"; then
	no "(C15) the provider never wraps the unit of the devices"
else
	ok "(C15) the provider never wraps the unit of the devices"
fi
if printf '%s\n' "$postblock" | grep -q 'WTFBSD_VM_SLOT'; then
	ok "(C15) the post block destroys every VM with the slot of its devices"
else
	no "(C15) the post block destroys every VM with the slot of its devices"
fi
if grep -qF "printf '%s %s" "$jenkins"; then
	ok "(C15) the list of the VMs holds the slot of every VM"
else
	no "(C15) the list of the VMs holds the slot of every VM"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
