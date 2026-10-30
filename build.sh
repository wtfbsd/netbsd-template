#!/bin/sh
#
# build.sh — build ExampleBSD-style images from an UNMODIFIED NetBSD tree.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# OVERLAY RULE: the NetBSD source tree and pkgsrc are never patched. This
# script applies overlay/base and overlay/profiles/<profile> on top of a
# stock NetBSD release and drives the stock tooling:
#
#   ./build.sh -U -j <jobs> -m <machine> -O <obj> -T <tools> tools release  (src/build.sh)
#   unpack <obj>/releasedir/<machine>/binary/sets/*.tar.xz         (release sets)
#   copy the overlay rootfs over the stage, substitute @DISTRO_NAME@ @MOTD@
#        @SLUG@ @BRAND_URL@ @ZFS_POOL_NAME@
#   pkg_add against a pkgsrc binary repository (PKG_PATH)           (pkgsrc)
#   nbmakefs -t ffs + nbinstallboot + a GPT layout                  (image)
#   sha256                                                         (out/SHA256)
#
# NetBSD cannot boot from ZFS: the root filesystem is FFS and ZFS is a
# data pool only. build.sh refuses any FILESYSTEM_ROOT other than ffs.
#
# The build runs as an ordinary user: the image metadata (owner, group and
# mode of every file) is written into a metadata spec that is handed to
# nbmakefs(1) with -F (the METALOG of the upstream build plus the overlay), so no chown(2) is needed and the image is correct
# whoever built it.
#
# product.conf is flat KEY=value output (parsed, never sourced) of
# wtfbsd/agents scripts/apply-answers.sh; the key list lives in
# wtfbsd/agents questions.yaml.
#
# Usage:
#   ./build.sh -c product.conf [-s /usr/src] [-o ./out] \
#              [-p desktop|appliance|both] [-n]
#
#   -c  product.conf (required; DISTRO_OS must be netbsd)
#   -s  unmodified NetBSD source tree (default /usr/src)
#   -o  output directory (default ./out)
#   -p  profile(s) to build; overrides PROFILE from product.conf
#   -n  dry run: validate the config, print the plan, change nothing
#
# Environment knobs:
#   ROOTSIZE  size of the root filesystem (default 12G)
#   ESPSIZE   size of the EFI system partition (default 64m)
#   DISKSIZE  size of the raw disk image (default: ROOTSIZE + 256m)
#   PKG_PATH  pkgsrc binary package repository used by pkg_add
#   WTFBSD_TOOLDIR  where the NetBSD tools (nbmakefs, nbgpt, ...) are
#             looked up; default: the tools directory of this build
#
set -eu
# The modes that reach the image never carry group/other write: build.sh
# sets umask 022, so every file it creates is 0644 (or 0755) and the
# staged files of a checkout are recorded after that umask.
umask 022

PROG=$(basename -- "$0")
log() { printf '%s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }

usage() {
	log "usage: $PROG -c product.conf [-s /usr/src] [-o ./out]"
	log '       [-p desktop|appliance|both] [-n]'
	log ''
	log '  -c  product.conf from wtfbsd/agents scripts/apply-answers.sh'
	log '  -s  unmodified NetBSD src tree (default /usr/src)'
	log '  -o  output directory (default ./out)'
	log '  -p  profile: desktop, appliance or both (default: product.conf PROFILE)'
	log '  -n  dry run: print the plan, change nothing'
	exit "${1:-2}"
}

DRY=0
CONF=''
SRC=/usr/src
OUT=./out
CHOSEN=''

while getopts 'c:s:o:p:nh' _opt; do
	case $_opt in
	c) CONF=$OPTARG ;;
	s) SRC=$OPTARG ;;
	o) OUT=$OPTARG ;;
	p) CHOSEN=$OPTARG ;;
	n) DRY=1 ;;
	h) usage 0 ;;
	*) usage 2 >&2 ;;
	esac
done
shift $((OPTIND - 1))
[ $# -eq 0 ] || usage 2 >&2
[ -n "$CONF" ] || {
	log "$PROG: missing -c product.conf" >&2
	usage 2 >&2
}
case $OUT in *[[:space:]]*) die "-o: output path may not contain whitespace: $OUT" ;; esac
[ -f "$CONF" ] || die "no such product.conf: $CONF"

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# --------------------------------------------------------------------------
# load + validate product.conf (flat KEY=value from apply-answers.sh)
# --------------------------------------------------------------------------

# product.conf is NEVER sourced: it is parsed line by line, only the known
# questions.yaml keys are accepted, and values may not contain shell
# metacharacters. One pair of outer quotes (single or double) is stripped.
KNOWN_KEYS='DISTRO_OS DISTRO_NAME DISTRO_SLUG DISTRO_ARCH FILESYSTEM_ROOT
ZFS_DATA_POOL ZFS_POOL_NAME PROFILE PACKAGE_SET INSTALLER MOTD BRAND_COLOR
BRAND_URL CI_ENABLED PUBLISH_METHOD PUBLISH_TARGET PUBLISHER_ORG'
for _k in $KNOWN_KEYS; do unset "$_k"; done
while IFS= read -r _line || [ -n "$_line" ]; do
	case $_line in '' | '#'*) continue ;; esac
	case $_line in
	[A-Z]*=*) ;;
	*) die "product.conf: not a KEY=value line: $_line" ;;
	esac
	_k=${_line%%=*}
	_v=${_line#*=}
	case " $(printf %s "$KNOWN_KEYS" | tr '\n' ' ') " in
	*" $_k "*) ;;
	*) die "product.conf: unknown key: $_k (known: $(printf %s "$KNOWN_KEYS" | tr '\n' ' '); see wtfbsd/agents questions.yaml)" ;;
	esac
	case $_v in
	\'*\') _v=${_v#\'}; _v=${_v%\'} ;;
	\"*\") _v=${_v#\"}; _v=${_v%\"} ;;
	esac
	case $_v in
	*[\$\`\\\'\"]* | *[[:cntrl:]]*) die "product.conf: $_k contains a forbidden character (\$, backquote, backslash, quote or control character)" ;;
	esac
	# plain assignments, no eval: the value is pure data
	case $_k in
	DISTRO_OS) DISTRO_OS=$_v ;;
	DISTRO_NAME) DISTRO_NAME=$_v ;;
	DISTRO_SLUG) DISTRO_SLUG=$_v ;;
	DISTRO_ARCH) DISTRO_ARCH=$_v ;;
	FILESYSTEM_ROOT) FILESYSTEM_ROOT=$_v ;;
	ZFS_DATA_POOL) ZFS_DATA_POOL=$_v ;;
	ZFS_POOL_NAME) ZFS_POOL_NAME=$_v ;;
	PROFILE) PROFILE=$_v ;;
	PACKAGE_SET) PACKAGE_SET=$_v ;;
	INSTALLER) INSTALLER=$_v ;;
	MOTD) MOTD=$_v ;;
	BRAND_COLOR) BRAND_COLOR=$_v ;;
	BRAND_URL) BRAND_URL=$_v ;;
	CI_ENABLED) CI_ENABLED=$_v ;;
	PUBLISH_METHOD) PUBLISH_METHOD=$_v ;;
	PUBLISH_TARGET) PUBLISH_TARGET=$_v ;;
	PUBLISHER_ORG) PUBLISHER_ORG=$_v ;;
	esac
done < "$CONF"

[ "${DISTRO_OS:-}" = netbsd ] \
	|| die "DISTRO_OS must be netbsd (got ${DISTRO_OS:-<empty>}); this template builds NetBSD only"

# anchored checks without interval expressions (portable ERE)
chk() { # chk <anchored-ere> <value> <message>
	printf '%s\n' "$2" | grep -qE -- "$1" || die "$3 (got: $2)"
}

# slug: lowercase/digits/hyphens, starts with a letter, 2..32 chars
chk '^[a-z][a-z0-9-]*$' "${DISTRO_SLUG:-}" 'DISTRO_SLUG must match ^[a-z][a-z0-9-]*$'
[ "$(printf %s "$DISTRO_SLUG" | wc -c)" -ge 2 ] || die 'DISTRO_SLUG too short (min 2)'
[ "$(printf %s "$DISTRO_SLUG" | wc -c)" -le 32 ] || die 'DISTRO_SLUG too long (max 32)'

case ${DISTRO_NAME:-} in *[[:cntrl:]]*) die 'DISTRO_NAME contains control characters' ;; esac
[ -n "${DISTRO_NAME:-}" ] || die 'DISTRO_NAME is empty'
[ "$(printf %s "$DISTRO_NAME" | wc -c)" -le 64 ] || die 'DISTRO_NAME too long (max 64)'

# The NetBSD honesty rule: NetBSD cannot boot from ZFS. The root filesystem
# is FFS; ZFS is available as a data pool only. See the per_os row of
# wtfbsd/agents questions.yaml (root_fs: ffs, zfs_pool: data-only).
FILESYSTEM_ROOT=${FILESYSTEM_ROOT:-ffs}
if [ "$FILESYSTEM_ROOT" != ffs ]; then
	die "FILESYSTEM_ROOT must be ffs for netbsd (got: $FILESYSTEM_ROOT).
NetBSD cannot boot from ZFS: the root filesystem stays FFS.
ZFS is available as a data pool only - answer ZFS_DATA_POOL=yes with
ZFS_POOL_NAME=<pool> and keep FILESYSTEM_ROOT=ffs."
fi

ZDP=${ZFS_DATA_POOL:-no}
case $ZDP in
yes | no) ;;
*) die "ZFS_DATA_POOL must be yes or no (got: $ZDP)" ;;
esac
if [ "$ZDP" = yes ]; then
	[ -n "${ZFS_POOL_NAME:-}" ] || die 'ZFS_DATA_POOL=yes requires ZFS_POOL_NAME'
	chk '^[a-z][a-z0-9-]*$' "$ZFS_POOL_NAME" 'ZFS_POOL_NAME must match ^[a-z][a-z0-9-]*$'
	[ "$(printf %s "$ZFS_POOL_NAME" | wc -c)" -le 29 ] || die 'ZFS_POOL_NAME too long (max 29)'
else
	ZFS_POOL_NAME=${ZFS_POOL_NAME:-}
fi

chk '^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$' \
	"${BRAND_COLOR:-2e7d66}" 'BRAND_COLOR must be six hex digits'
BRAND_URL=${BRAND_URL:-https://example.org}
chk '^https://[A-Za-z0-9.-]+$' "$BRAND_URL" 'BRAND_URL must be https, hostname only'

PROF=${CHOSEN:-${PROFILE:-appliance}}
case $PROF in
desktop | appliance | both) ;;
*) die "-p must be desktop, appliance or both (got: $PROF)" ;;
esac

# informational defaults mirroring questions.yaml (used downstream)
PACKAGE_SET=${PACKAGE_SET:-minimal}
INSTALLER=${INSTALLER:-tui}
MOTD=${MOTD:-built from the wtfbsd templates}
case $MOTD in *[[:cntrl:]]*) die 'MOTD contains control characters' ;; esac
[ "$(printf %s "$MOTD" | wc -c)" -le 120 ] || die 'MOTD too long (max 120)'

# --------------------------------------------------------------------------
# static checks
# --------------------------------------------------------------------------

# The wireless-driver rule: the driver is never enabled, loaded or
# configured by this template, and an overlay file may not mention it at
# all. The token is assembled at run time, so that no file of this
# repository contains the name of that driver.
[ -d "$ROOT/overlay" ] || die "overlay guard: missing $ROOT/overlay"
_driver=$(printf 'mt%s' '76')
_rc=0
grep -rna -- "$_driver" "$ROOT/overlay" || _rc=$?
case $_rc in
1) ;; # no match: good
0) die 'overlay guard: an overlay file references the forbidden wireless driver; it must never be enabled or loaded by this template' ;;
*) die "overlay guard: could not scan $ROOT/overlay (grep exit $_rc)" ;;
esac

: "${DISTRO_ARCH:=amd64}" # questions.yaml per_os default
case $DISTRO_ARCH in
amd64 | aarch64) MACHINE=$DISTRO_ARCH ;;
*) die "DISTRO_ARCH must be amd64 or aarch64 (got: ${DISTRO_ARCH:-<empty>})" ;;
esac

if [ "$DRY" -ne 1 ]; then
	command -v tar > /dev/null 2>&1 || die 'required tool missing: tar'
	[ -d "$SRC" ] || die "no such src tree: $SRC (clone an unmodified NetBSD src there, or pass -s <path>)"
	[ -f "$SRC/build.sh" ] || die "$SRC does not look like a NetBSD src tree (no build.sh)"
fi

# --------------------------------------------------------------------------
# paths
# --------------------------------------------------------------------------

# The output directory is absolute from here on: the build is driven from
# the source tree (cd "$SRC" && ./build.sh ...), so a relative -O or -T
# would land inside the NetBSD source tree instead of in the output
# directory.
abspath() { # abspath <path> — an absolute path, without touching the disk
	case $1 in
	/*) printf '%s\n' "$1" ;;
	*) printf '%s\n' "$PWD/${1#./}" ;;
	esac
}

OUT=$(abspath "$OUT")

JOBS=${JOBS:-$(nproc 2>/dev/null || echo 1)}
ROOTSIZE=${ROOTSIZE:-12G}
ESPSIZE=${ESPSIZE:-64m}
OBJ="$OUT/obj"
TOOLS="$OUT/tools"
# where the NetBSD tools are looked up: nbmakefs, nbgpt, nbinstallboot and
# nbpwd_mkdb live in the tools directory of the upstream build
TOOLDIR=${WTFBSD_TOOLDIR:-$TOOLS}
SETS="$OBJ/releasedir/$MACHINE/binary/sets"
# The METALOG of the upstream build: the metadata of the base system. The
# upstream build writes it into its destdir (install -U -M); it is what
# the metadata of the image is built from.
BASE_METALOG="$OBJ/destdir.$MACHINE/METALOG"

# The GPT partition type of a NetBSD FFS partition. NetBSD's loader looks
# for its own type; see gpt(8). The GUID is listed as unverified in the
# round report.
NETBSD_FFS_TYPE='49f48d5a-b10e-11dc-b99b-0019d1879648'

# The EFI loader of the machine, and the file name it takes on the EFI
# system partition. On NetBSD /boot is the kernel: a FILE, not a
# directory, and the EFI loader is /usr/mdec/bootx64.efi.
case $MACHINE in
amd64)
	EFI_LOADER=bootx64.efi
	EFI_BOOT_NAME=BOOTX64.EFI
	;;
aarch64)
	EFI_LOADER=bootaa64.efi
	EFI_BOOT_NAME=BOOTAA64.EFI
	;;
esac

# The pkgsrc name of the architecture of the image: pkgsrc calls the
# amd64 architecture x86_64.
case $MACHINE in
amd64) PKGSRC_ARCH=x86_64 ;;
aarch64) PKGSRC_ARCH=aarch64 ;;
esac

# The FFS version of the root filesystem and the boot block that belongs to
# it. installboot(8) takes the boot block as its second argument, and the
# boot block must match the file system version: bootxx_ffsv1 for FFSv1
# (-t ffs), bootxx_ffsv2 for FFSv2 (-t ffs2).
FFS_TYPE=ffs
BOOT_BLOCK=bootxx_ffsv1

# The release sets that carry the X11 stack. The X11 of this distribution
# comes from pkgsrc (see the desktop profile), so these sets are not
# unpacked: the image has exactly one X11 in it. The set names are the
# ones of the NetBSD release: there is no "x11" set.
X_SETS='xbase xcomp xetc xfont xserver'

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

step() { # step <cmd...> — execute, or print in a dry run
	if [ "$DRY" -eq 1 ]; then printf '    + %s\n' "$*"; else "$@"; fi
}

rmrf() { # rmrf <path> <guardroot> — rm -rf only for non-empty paths under root
	[ -n "${1:-}" ] || die 'rmrf: empty path'
	[ -n "${2:-}" ] || die 'rmrf: empty guard root'
	[ "$1" != "$2" ] || die "rmrf: refusing guard root itself: $1"
	case $1 in "$2"/*) ;; *) die "rmrf: refusing path outside $2: $1" ;; esac
	[ -d "$1" ] || return 0
	rm -rf -- "$1"
}

tool() { # tool <name> — the path of a build tool
	_n=$1
	if [ -x "$TOOLDIR/bin/$_n" ]; then
		printf '%s\n' "$TOOLDIR/bin/$_n"
	else
		printf '%s\n' "$_n"
	fi
}

pkg_list() { # pkg_list file... — flatten lists to shell words
	sed -e 's/[[:space:]]*#.*$//' \
		-e 's/^[[:space:]]*//' \
		-e 's/[[:space:]]*$//' "$@" | grep -v '^$' | tr '\n' ' '
}

sed_esc() { # escape a value for use inside a sed replacement
	printf '%s' "$1" | sed -e 's/[\\&]/\\&/g'
}

sums() { # sums <file> — print a sha256 checksum of a file
	if command -v sha256 > /dev/null 2>&1; then
		sha256 "$1"
	elif command -v sha256sum > /dev/null 2>&1; then
		sha256sum "$1"
	elif command -v shasum > /dev/null 2>&1; then
		shasum -a 256 "$1"
	else
		die 'no sha256 tool found (sha256, sha256sum or shasum)'
	fi
}

size_bytes() { # size_bytes <size> — a size like 12G in bytes
	_s=$1
	_u=1
	case $_s in
	*[Kk]) _u=1024; _s=${_s%?} ;;
	*[Mm]) _u=1048576; _s=${_s%?} ;;
	*[Gg]) _u=1073741824; _s=${_s%?} ;;
	*[Tt]) _u=1099511627776; _s=${_s%?} ;;
	esac
	case $_s in
	'' | *[!0-9]*) die "cannot parse the size: $1" ;;
	esac
	printf '%s\n' "$(( _s * _u ))"
}

fmt_size() { # fmt_size <bytes> — a byte count as a size like 13G (rounded up)
	_b=$1
	if [ "$_b" -ge 1073741824 ]; then
		printf '%dG\n' "$(( (_b + 1073741823) / 1073741824 ))"
	elif [ "$_b" -ge 1048576 ]; then
		printf '%dM\n' "$(( (_b + 1048575) / 1048576 ))"
	else
		printf '%dK\n' "$(( (_b + 1023) / 1024 ))"
	fi
}

mode_of() { # mode_of <path> — the permission bits of a file, as octal
	if stat -c '%a' -- "$1" 2> /dev/null; then return 0; fi
	if stat -f '%Lp' -- "$1" 2> /dev/null; then return 0; fi
	die "no usable stat(1) to read the mode of $1"
}

overlay_mode() { # overlay_mode <stage-relative-path> — the mode of an overlay file
	# The modes of the image come from this table, never from the
	# checkout: the modes of this repository never reach the image.
	case $1 in
	etc/rc.d/* | etc/rc.init/* | usr/local/sbin/* | usr/local/bin/* | \
		usr/sbin/* | usr/bin/* | usr/pkg/bin/* | usr/pkg/sbin/*)
		printf '0755\n'
		;;
	*)
		printf '0644\n'
		;;
	esac
}

SUBFILE=''
mk_subst() { # write a sed program under OUT; pick a delimiter absent from values
	SUBFILE="$OUT/.subst.sed"
	d=''
	for cand in '|' ',' ';' ':' '%'; do
		case "$DISTRO_NAME$MOTD$DISTRO_SLUG$BRAND_URL$ZFS_POOL_NAME" in
		*"$cand"*) ;;
		*) d=$cand; break ;;
		esac
	done
	[ -n "$d" ] || die 'DISTRO_NAME/MOTD/DISTRO_SLUG/BRAND_URL contain every candidate sed delimiter (| , ; : %); remove one of those characters in product.conf'
	{
		printf 's%s@DISTRO_NAME@%s%s%sg\n' "$d" "$d" "$(sed_esc "$DISTRO_NAME")" "$d"
		printf 's%s@MOTD@%s%s%sg\n' "$d" "$d" "$(sed_esc "$MOTD")" "$d"
		printf 's%s@SLUG@%s%s%sg\n' "$d" "$d" "$(sed_esc "$DISTRO_SLUG")" "$d"
		printf 's%s@BRAND_URL@%s%s%sg\n' "$d" "$d" "$(sed_esc "$BRAND_URL")" "$d"
		printf 's%s@ZFS_POOL_NAME@%s%s%sg\n' "$d" "$d" "$(sed_esc "$ZFS_POOL_NAME")" "$d"
	} > "$SUBFILE"
}

subst_overlay() { # subst_overlay <stage> <overlay-rootfs-dir>
	_stg=$1 _ovr=$2
	find "$_ovr" -type f | while read -r f; do
		r=${f#"$_ovr"/}
		t="$_stg/$r"
		[ -f "$t" ] || continue
		# the rewrite keeps the mode of the file it replaces: a script
		# stays a script
		_m=$(mode_of "$t")
		sed -f "$SUBFILE" "$t" > "$t.new" && mv "$t.new" "$t"
		chmod "$_m" "$t"
	done
}

copy_overlay() { # copy_overlay <overlay-rootfs-dir> <stage>
	_ovr=$1 _stg=$2
	# no -p: the owner and the modes of this checkout must never end up
	# on the system directories of the image
	cp -R "$_ovr/." "$_stg/"
}

set_overlay_modes() { # set_overlay_modes <overlay-rootfs-dir> <stage>
	_ovr=$1 _stg=$2
	find "$_ovr" -type d | while read -r d; do
		r=${d#"$_ovr"/}
		[ "$r" = "$_ovr" ] && continue
		[ -d "$_stg/$r" ] || continue
		chmod 755 "$_stg/$r"
	done
	find "$_ovr" -type f | while read -r d; do
		r=${d#"$_ovr"/}
		[ -f "$_stg/$r" ] || continue
		chmod "$(overlay_mode "$r")" "$_stg/$r"
	done
}

overlay_paths() { # overlay_paths <overlay-rootfs-dir>... — the paths of the overlay
	# The paths are the ones of the stage, with a ./ in front: the
	# metadata spec has the same shape as the METALOG of the upstream
	# build. A path whose name holds @SLUG@ is renamed by the build, so
	# the slug is substituted here as well.
	for _ovr in "$@"; do
		[ -d "$_ovr" ] || continue
		find "$_ovr" | LC_ALL=C sort | while read -r _abs; do
			_r=${_abs#"$_ovr"}
			[ -n "$_r" ] || continue
			printf './%s\n' "${_r#/}"
		done
	done | sed "s|@SLUG@|$DISTRO_SLUG|g"
}

gen_spec() { # gen_spec <stage> <spec-out> <base-metalog> <overlay-paths>
	# The metadata of the image.
	#
	# The METALOG of the upstream build describes the base system: the
	# modes of /tmp, of su and of everything else the release sets
	# carry. Those modes are never rebuilt from the files of this
	# checkout: an unprivileged tar drops the setuid bits, and a
	# rebuild from the host modes flattens /tmp to 0755 and su to 0555.
	#
	# The entries of the files that the build adds on top of the base
	# system are appended: the files of the overlay (with the modes of
	# the table of overlay_mode), the packages and the files build.sh
	# writes.
	_stage=$1 _out=$2 _base=$3 _ovl=$4
	[ -f "$_base" ] || die "no METALOG of the upstream build: $_base
The metadata of the image is built from it: the modes of the base system
are never rebuilt from the files of this build."
	# the raw spec is ordered once at the end, after everything is gathered
	_raw=$_out.raw
	: > "$_raw"
	# 1. the base system, without the entries of the paths the overlay
	#    replaces. The raw spec is ordered below, after everything has
	#    been gathered, so that it only has to be sorted once.
	awk -v ovl="$_ovl" '
		BEGIN { while ((getline l < ovl) > 0) drop[l] = 1 }
		{ if (!($1 in drop)) print }
	' "$_base" > "$_raw"
	# 2. the overlay: the files and the directories it adds, appended
	#    after the base so that a base entry is replaced in place by the
	#    overlay one (never dropped and re-appended after its children)
	while IFS= read -r _p; do
		[ -n "$_p" ] || continue
		_f="$_stage/${_p#./}"
		if [ -h "$_f" ]; then
			# a symlink is a link, never a directory
			printf '%s type=link link=%s uname=root gname=wheel\n' \
				"$_p" "$(readlink "$_f")" >> "$_raw"
		elif [ -d "$_f" ]; then
			printf '%s type=dir mode=0755 uname=root gname=wheel\n' "$_p" >> "$_raw"
		elif [ -f "$_f" ]; then
			printf '%s type=file mode=%s uname=root gname=wheel\n' \
				"$_p" "$(overlay_mode "${_p#./}")" >> "$_raw"
		fi
	done < "$_ovl"
	# 3. the files the build adds on top of the base system: the
	#    packages and the files build.sh writes. They belong to
	#    root:wheel, and they are recorded after umask 022, so that they
	#    never carry group/other write.
	awk '{ print $1 }' "$_base" | LC_ALL=C sort -u > "$_out.base"
	find "$_stage" | LC_ALL=C sort |
		awk -v s="$_stage" '{ print "." substr($0, length(s) + 1) }' > "$_out.stage"
	awk -v base="$_out.base" -v ovl="$_ovl" '
		BEGIN {
			while ((getline l < base) > 0) known[l] = 1
			while ((getline l < ovl) > 0) known[l] = 1
		}
		{ if (!($1 in known)) print }
	' "$_out.stage" > "$_out.added"
	while IFS= read -r _p; do
		[ -n "$_p" ] || continue
		_f="$_stage/${_p#./}"
		if [ -h "$_f" ]; then
			printf '%s type=link link=%s uname=root gname=wheel\n' \
				"$_p" "$(readlink "$_f")" >> "$_raw"
		elif [ -d "$_f" ]; then
			printf '%s type=dir mode=0755 uname=root gname=wheel\n' "$_p" >> "$_raw"
		elif [ -f "$_f" ]; then
			_m=$(mode_of "$_f")
			case $_m in
			[0-7][0-7][0-7]) _m=0$_m ;;
			esac
			# umask 022: strip group/other write, keep setuid/sticky
			_m=$(printf '%o' "$(( 0$_m & 07755 ))")
			case $_m in
			[0-7][0-7][0-7]) _m=0$_m ;;
			esac
			printf '%s type=file mode=%s uname=root gname=wheel\n' "$_p" "$_m" >> "$_raw"
		fi
	done < "$_out.added"
	rm -f "$_out.base" "$_out.stage" "$_out.added"
	# 4. order the spec so that makefs(8) finds every directory before the
	#    files it holds: the leading comment and /set lines stay on top,
	#    the paths are sorted (LC_ALL=C) so that a parent precedes its
	#    children, and every path is in the spec exactly once
	#    A line that is not in full-path form would be moved by the
	#    sort away from its parent: the relative paths of an mtree
	#    spec are not the paths of the image. Such a line is refused
	#    here, and the line that is wrong is named.
	_bad=$(awk '
		/^[[:space:]]*$/ { next }
		/^#/ { next }
		/^\/set/ { next }
		/^\.$/ { next }
		/^\.[[:space:]]/ { next }
		/^\.\// { next }
		{ print; exit }
	' "$_raw")
	[ -z "$_bad" ] || die "METALOG line is not in full-path form: $_bad"
	{
		grep -E '^#|^/set' "$_raw" || true
		grep -vE '^#|^/set' "$_raw" | LC_ALL=C sort -k1,1
	} > "$_out"
	rm -f "$_raw"
}

lock_root() { # lock_root <stage>
	# The stock release leaves root with an EMPTY password. The account
	# is locked here: the password field of root in master.passwd becomes
	# "*" and the password database is rebuilt from it.
	_stg=$1
	_mp="$_stg/etc/master.passwd"
	[ -f "$_mp" ] || die "no $_mp: the release sets did not provide a password database"
	awk -F: 'BEGIN { OFS = ":" } $1 == "root" { $2 = "*" } { print }' "$_mp" > "$_mp.new"
	chmod 600 "$_mp.new"
	mv "$_mp.new" "$_mp"
	# the owner of the file is root:wheel in the image (the metadata spec
	# says so); chown is only possible for a build that runs as root
	if [ "$(id -u)" -eq 0 ]; then
		chown root:wheel "$_mp"
	fi
	# -d is the root directory of the staged system; the meaning of -p is
	# listed as unverified in the round report
	"$(tool nbpwd_mkdb)" -p -d "$_stg" "$_mp"
}

gpt_offset() { # gpt_offset <gpt-show-file> <index> — the start of a partition
	# The rows are selected by their INDEX column, not by their order:
	# the first rows of a gpt(8) listing are the PMBR, the primary GPT
	# header and the primary GPT table, and their index column holds
	# numbers of its own.
	awk -v want="$2" '
		$1 ~ /^[0-9]+$/ && $3 == want && $4 !~ /^(PMBR|Pri)$/ { print $1; exit }
	' "$1"
}

# The architecture of a pkgsrc binary repository, when the path makes it
# clear. The real shape of a binary repository is
# .../NetBSD/<arch>/<version>/All; the older one is
# .../NetBSD-<version>-<arch>. A path of any other shape says nothing
# about the architecture: only a clear mismatch is refused.
pkg_arch_of_path() { # pkg_arch_of_path <path> — the pkgsrc architecture
	_p=$1
	# the real shape: .../NetBSD/<arch>/<version>/All
	_a=$(printf '%s\n' "$_p" | awk -F/ '
		{ for (i = 1; i < NF; i++) if ($i == "NetBSD") { print $(i + 1); exit } }
	')
	if [ -n "$_a" ]; then
		printf '%s\n' "$_a"
		return 0
	fi
	# the older shape: the last component names the architecture
	_b=${_p##*/}
	case $_b in
	All | all | pkg | '') return 0 ;;
	esac
	printf '%s\n' "$_b" | sed -n 's/.*-\([^-]*\)$/\1/p'
}

check_pkg_arch() { # refuse a package repository built for another architecture
	[ -n "${PKG_PATH:-}" ] || return 0
	printf '%s\n' "$PKG_PATH" | tr ':' '\n' > "$OUT/.pkgpath"
	while IFS= read -r _p; do
		[ -n "$_p" ] || continue
		_a=$(pkg_arch_of_path "$_p")
		# the path does not make the architecture clear: nothing is
		# refused
		[ -n "$_a" ] || continue
		case $_a in
		"$MACHINE" | "$PKGSRC_ARCH") continue ;;
		esac
		die "PKG_PATH points at a repository for another architecture ($_a); this image is $MACHINE ($PKGSRC_ARCH)"
	done < "$OUT/.pkgpath"
}

# --------------------------------------------------------------------------
# plan header
# --------------------------------------------------------------------------

# the disk holds the EFI system partition, the root filesystem and the GPT
# overhead, so it is always a little larger than the two of them together
ROOTB=$(size_bytes "$ROOTSIZE")
ESPB=$(size_bytes "$ESPSIZE")
DISKSIZE=${DISKSIZE:-$(fmt_size $((ROOTB + ESPB + 134217728)))}
DISKB=$(size_bytes "$DISKSIZE")

log ''
log 'plan:'
log "  distro   $DISTRO_NAME ($DISTRO_SLUG), netbsd/$DISTRO_ARCH"
log "  rootfs   $FILESYSTEM_ROOT (zfs data pool: $ZDP${ZFS_POOL_NAME:+ ($ZFS_POOL_NAME)})"
log "  profile  $PROF (package set: $PACKAGE_SET, installer: $INSTALLER)"
log "  src      $SRC (unmodified; obj: $OBJ, tools: $TOOLS)"
log "  out      $OUT  (jobs: $JOBS, rootsize: $ROOTSIZE, esp: $ESPSIZE, disk: $DISKSIZE)"

case $PROF in
both) profiles='appliance desktop' ;;
*) profiles=$PROF ;;
esac

if [ "$DRY" -ne 1 ]; then
	mkdir -p "$OUT"
	# the canonical path of the output directory (symlinks resolved)
	OUT=$(CDPATH='' cd -- "$OUT" && pwd)
	OBJ="$OUT/obj"
	TOOLS="$OUT/tools"
	TOOLDIR=${WTFBSD_TOOLDIR:-$TOOLS}
	SETS="$OBJ/releasedir/$MACHINE/binary/sets"
	check_pkg_arch
fi

# --------------------------------------------------------------------------
# the release sets (built once, unpacked per profile)
# --------------------------------------------------------------------------

log ''
log '==> netbsd release (upstream src/build.sh, unmodified tree)'
if [ "$DRY" -eq 1 ]; then
	printf '    + cd %s && ./build.sh -U -j %s -m %s -O %s -T %s tools release\n' "$SRC" "$JOBS" "$MACHINE" "$OBJ" "$TOOLS"
	printf '    + sets: %s/*.tar.xz are the release sets\n' "$SETS"
else
	mkdir -p "$OBJ" "$TOOLS"
	(cd "$SRC" && ./build.sh -U -j "$JOBS" -m "$MACHINE" -O "$OBJ" -T "$TOOLS" tools release)
	[ -d "$SETS" ] || die "no release sets in $SETS"
fi

RELS='' # relative artifact paths; safe to word-split: the slug is [a-z0-9-]

for p in $profiles; do
	log ''
	log "==> profile: $p"

	PSUB="$OUT/$p"
	STAGE="$PSUB/stage"
	PARTS="$PSUB/parts"
	METALOG="$PSUB/metalog"
	img="$PSUB/$DISTRO_SLUG-$p-$MACHINE.img"

	# 1. unpack the release sets into the stage
	log '  [1] release sets -> stage'
	if [ "$DRY" -eq 1 ]; then
		printf '    + mkdir -p %s\n' "$STAGE"
		printf '    + tar -xJf %s/<set>.tar.xz -C %s   (every set except the X11 sets: %s)\n' \
			"$SETS" "$STAGE" "$X_SETS"
	else
		rmrf "$STAGE" "$OUT"
		rmrf "$PARTS" "$OUT"
		mkdir -p "$STAGE" "$PARTS"
		for set in "$SETS"/*.tar.xz; do
			[ -f "$set" ] || continue
			_skip=0
			for x in $X_SETS; do
				case ${set##*/} in
				"$x".tar.xz) _skip=1 ;;
				esac
			done
			[ "$_skip" -eq 0 ] || continue
			"$(tool tar)" -xJf "$set" -C "$STAGE"
		done
		# on NetBSD /boot is the kernel: a file, not a directory
		[ -f "$STAGE/netbsd" ] || die "the release sets did not unpack into $STAGE"
	fi

	# 2. copy the overlay rootfs: base first, then the profile on top
	log '  [2] overlay copy + placeholder substitution'
	if [ "$DRY" -eq 1 ]; then
		printf '    + cp -R %s/rootfs/. %s/\n' "$ROOT/overlay/base" "$STAGE"
		printf '    + cp -R %s/rootfs/. %s/\n' "$ROOT/overlay/profiles/$p" "$STAGE"
		printf '    + sed -f %s (every staged overlay file: @DISTRO_NAME@ @MOTD@ @SLUG@ @BRAND_URL@ @ZFS_POOL_NAME@)\n' "$OUT/.subst.sed"
		printf '    + rename staged files/dirs whose NAME contains @SLUG@ -> %s\n' "$DISTRO_SLUG"
		printf '    + cp %s/etc/motd.template -> %s/etc/motd\n' "$STAGE" "$STAGE"
	else
		mk_subst
		copy_overlay "$ROOT/overlay/base/rootfs" "$STAGE"
		copy_overlay "$ROOT/overlay/profiles/$p/rootfs" "$STAGE"
		subst_overlay "$STAGE" "$ROOT/overlay/base/rootfs"
		subst_overlay "$STAGE" "$ROOT/overlay/profiles/$p/rootfs"
		# staged files whose NAME contains @SLUG@ belong to the product
		_slugs=$(find "$STAGE" -depth -name '*@SLUG@*')
		for _sf in $_slugs; do
			_sf_new=$(printf %s "$_sf" | sed -e "s%@SLUG@%$DISTRO_SLUG%g")
			if [ "$_sf" != "$_sf_new" ]; then
				mv "$_sf" "$_sf_new"
			fi
		done
		# NetBSD has no motd template mechanism: the live file is the motd
		cp "$STAGE/etc/motd.template" "$STAGE/etc/motd"
		chmod 644 "$STAGE/etc/motd"
		# the modes of the overlay files are set here, not inherited
		set_overlay_modes "$ROOT/overlay/base/rootfs" "$STAGE"
		set_overlay_modes "$ROOT/overlay/profiles/$p/rootfs" "$STAGE"
	fi

	# 3. system configuration: /etc/rc.conf, rc.conf.d fragments
	log '  [3] rc.conf and rc.conf.d fragments'
	if [ "$DRY" -eq 1 ]; then
		printf '    + set rc_configured="YES" in %s/etc/rc.conf\n' "$STAGE"
		printf '    + %s/etc/rc.conf.d/<service> fragments of the %s profile come from the overlay\n' "$STAGE" "$p"
		printf '    + %s/etc/myname holds the host name (%s)\n' "$STAGE" "$DISTRO_SLUG"
		printf '    + %s/etc/fstab names the root filesystem by its GPT label (%sroot)\n' "$STAGE" "$DISTRO_SLUG"
		if [ "$ZDP" = yes ]; then
			printf '    + write %s/etc/rc.conf.d/zfs: zfs=YES (the data pool %s is created by hand)\n' \
				"$STAGE" "$ZFS_POOL_NAME"
		fi
		printf '    + lock root in %s/etc/master.passwd and rebuild the password database\n' "$STAGE"
	else
		# rc.conf(5): rc_configured=YES is what makes rc(8) run the
		# per-service scripts at boot. The stock file is edited in place
		# (staged copy only), never replaced.
		if [ -f "$STAGE/etc/rc.conf" ]; then
			if grep -q '^rc_configured=' "$STAGE/etc/rc.conf"; then
				sed 's/^rc_configured=.*/rc_configured="YES"/' \
					"$STAGE/etc/rc.conf" > "$STAGE/etc/rc.conf.new"
				mv "$STAGE/etc/rc.conf.new" "$STAGE/etc/rc.conf"
			else
				printf '\nrc_configured="YES"\n' >> "$STAGE/etc/rc.conf"
			fi
		else
			printf 'rc_configured="YES"\n' > "$STAGE/etc/rc.conf"
		fi
		if [ "$ZDP" = yes ]; then
			# zfs(8): the rc script loads the module and imports the
			# pools. The data pool itself is created by hand.
			printf 'zfs=YES\n' > "$STAGE/etc/rc.conf.d/zfs"
			chmod 644 "$STAGE/etc/rc.conf.d/zfs"
		fi
		# the stock release leaves root with an empty password
		lock_root "$STAGE"
		# the sentinel of the first-boot script: NetBSD has no KEYWORD
		# firstboot, so the script runs once and removes the sentinel
		if [ -f "$STAGE/etc/rc.d/firstboot_user" ]; then
			mkdir -p "$STAGE/var/db"
			: > "$STAGE/var/db/firstboot_user"
			chmod 644 "$STAGE/var/db/firstboot_user"
		fi
	fi

	# 4. pkgsrc packages: base list + profile list, installed into the stage
	log '  [4] pkgsrc packages (pkg_add)'
	# the package names come from the static packages.list files, so the
	# word split of $pkgs here is wanted (one package per word)
	pkgs=$(pkg_list "$ROOT/overlay/base/packages.list" "$ROOT/overlay/profiles/$p/packages.list")
	if [ -n "$pkgs" ]; then
		# PKG_RCD_SCRIPTS=YES installs the rc.d scripts of the packages
		# into /etc/rc.d of the stage, where rc(8) finds them.
		# The -P destination option of pkg_add(1) is marked unverified:
		# the pkgsrc manual page is the reference.
		if [ -n "${PKG_PATH:-}" ]; then
			step env 'PKG_RCD_SCRIPTS=YES' "PKG_PATH=$PKG_PATH" "$(tool pkg_add)" -P "$STAGE" $pkgs
		else
			step env 'PKG_RCD_SCRIPTS=YES' "$(tool pkg_add)" -P "$STAGE" $pkgs
		fi
	else
		log '    (no packages)'
	fi

	# 5. the image: a NetBSD FFS root, an EFI system partition and a GPT
	#    layout that puts them on one raw disk
	log '  [5] image (nbmakefs, nbinstallboot, GPT)'
	if [ "$DRY" -eq 1 ]; then
		printf '    + write %s/metalog (the METALOG of the upstream build, then the entries of the overlay)\n' "$PSUB"
		printf '    + nbmakefs -t %s -F %s/metalog -N %s/etc -B little -s %s -o label=%s %s/root.img %s\n' \
			"$FFS_TYPE" "$PSUB" "$STAGE" "$ROOTSIZE" "$DISTRO_SLUG" "$PARTS" "$STAGE"
		printf '    + nbinstallboot -m %s %s/root.img %s/usr/mdec/%s\n' \
			"$MACHINE" "$PARTS" "$STAGE" "$BOOT_BLOCK"
		printf '    + mkdir -p %s/efi/EFI/BOOT; cp %s/usr/mdec/%s %s/efi/EFI/BOOT/%s\n' \
			"$PARTS" "$STAGE" "$EFI_LOADER" "$PARTS" "$EFI_BOOT_NAME"
		printf '    + nbmakefs -t msdos -s %s -o fat_type=16 %s/efi.img %s/efi\n' "$ESPSIZE" "$PARTS" "$PARTS"
		printf '    + dd the disk image (%s), then nbgpt create; nbgpt add -t efi -l %sesp; nbgpt add -t %s -l %sroot\n' \
			"$DISKSIZE" "$DISTRO_SLUG" "$NETBSD_FFS_TYPE" "$DISTRO_SLUG"
		printf '    + dd the ESP and the root filesystem into the disk image at their partition offsets\n'
	else
		# the paths of the overlay: the files and the directories it
		# adds to the stage
		OVLPATHS="$PSUB/overlay.paths"
		overlay_paths "$ROOT/overlay/base/rootfs" "$ROOT/overlay/profiles/$p/rootfs" |
			LC_ALL=C sort -u > "$OVLPATHS"
		gen_spec "$STAGE" "$METALOG" "$BASE_METALOG" "$OVLPATHS"
		# -N: the user and the group names of the image are resolved
		# from the passwd and the group of the target, never from the
		# ones of the host that builds it
		"$(tool nbmakefs)" -t "$FFS_TYPE" -F "$METALOG" -N "$STAGE/etc" -B little -s "$ROOTSIZE" \
			-o "label=$DISTRO_SLUG" "$PARTS/root.img" "$STAGE"
		# the boot block belongs to the file system version of the image
		[ -f "$STAGE/usr/mdec/$BOOT_BLOCK" ] \
			|| die "no $STAGE/usr/mdec/$BOOT_BLOCK: the release does not provide that boot block"
		"$(tool nbinstallboot)" -m "$MACHINE" "$PARTS/root.img" "$STAGE/usr/mdec/$BOOT_BLOCK"
		mkdir -p "$PARTS/efi/EFI/BOOT"
		[ -f "$STAGE/usr/mdec/$EFI_LOADER" ] \
			|| die "no $STAGE/usr/mdec/$EFI_LOADER: the release does not provide the EFI loader"
		cp "$STAGE/usr/mdec/$EFI_LOADER" "$PARTS/efi/EFI/BOOT/$EFI_BOOT_NAME"
		# fat_type is the name of the option in makefs(1); it is listed
		# as unverified in the round report
		"$(tool nbmakefs)" -t msdos -s "$ESPSIZE" \
			-o fat_type=16 "$PARTS/efi.img" "$PARTS/efi"
		# the disk image is created first: the GPT is written into it
		_disk_mb=$(( (DISKB + 1048575) / 1048576 ))
		"$(tool dd)" if=/dev/zero of="$PARTS/disk.img" bs=1m count=0 seek="$_disk_mb"
		"$(tool nbgpt)" create "$PARTS/disk.img"
		"$(tool nbgpt)" add -t efi -s "$ESPSIZE" -i 1 -l "${DISTRO_SLUG}esp" "$PARTS/disk.img"
		"$(tool nbgpt)" add -t "$NETBSD_FFS_TYPE" -s "$ROOTSIZE" -i 2 -l "${DISTRO_SLUG}root" "$PARTS/disk.img"
		# the listing is read as the gpt(8) layout: start, size, index
		# and contents, with the PMBR, the primary GPT header and the
		# primary GPT table first. The offsets are in 512 byte blocks,
		# which is the unit of the dd below; both are listed as
		# unverified in the round report.
		_gptshow="$PARTS/gpt.show"
		"$(tool nbgpt)" show -p "$PARTS/disk.img" > "$_gptshow"
		_esp_off=$(gpt_offset "$_gptshow" 1)
		_root_off=$(gpt_offset "$_gptshow" 2)
		[ -n "$_esp_off" ] && [ -n "$_root_off" ] || die "cannot read the partition offsets of $PARTS/disk.img"
		"$(tool dd)" if="$PARTS/efi.img" of="$PARTS/disk.img" bs=512 seek="$_esp_off" conv=notrunc
		"$(tool dd)" if="$PARTS/root.img" of="$PARTS/disk.img" bs=512 seek="$_root_off" conv=notrunc
		mv "$PARTS/disk.img" "$img"
	fi
	log "    -> $img"

	rimg=${img#"$OUT"/}
	RELS="$RELS $rimg"

	log "profile done: $p (root $FILESYSTEM_ROOT, machine $MACHINE)"
done

# --------------------------------------------------------------------------
# checksums
# --------------------------------------------------------------------------

log ''
log '== checksums =='
if [ "$DRY" -eq 1 ]; then
	printf '    + sha256 %s > %s/SHA256\n' "${RELS# }" "$OUT"
else
	: > "$OUT/SHA256"
	for rel in $RELS; do
		sums "$OUT/$rel" >> "$OUT/SHA256"
	done
	log "wrote: $OUT/SHA256"
fi
log 'artifacts:'
for rel in $RELS; do
	log "  $OUT/$rel"
done

if [ "$DRY" -eq 1 ]; then
	log ''
	log 'dry run: plan printed above; nothing was built'
else
	log ''
	log "done: $profiles under $OUT"
fi
