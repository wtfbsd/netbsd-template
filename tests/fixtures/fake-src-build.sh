#!/bin/sh
# tests/fixtures/fake-src-build.sh — the fake upstream NetBSD build.sh.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# The real build runs "(cd $SRC && ./build.sh -U -m <machine> -O <obj>
# -T <tools> tools release)" and then unpacks the release sets that land in
# <obj>/releasedir/<machine>/binary/sets. This stand-in publishes the set
# tarballs prepared by the test harness in that directory, so that the
# REAL build path can run without a NetBSD source tree.
#
# Environment:
#   FAKE_SETS_DIR  the directory with the prepared set tarballs
#   STUB_LOG       the log the call is appended to
#   FAKE_METALOG_NOHEADER  the METALOG is written without its
#                   "#mtree" header line
#   FAKE_METALOG_RELATIVE  the METALOG holds a relative path ("..")

set -eu

ORIGINAL="$*"

OBJ=''
MACHINE=''
while [ $# -gt 0 ]; do
	case $1 in
	-O)
		OBJ=${2:-}
		shift 2
		;;
	-m)
		MACHINE=${2:-}
		shift 2
		;;
	-T)
		shift 2
		;;
	*)
		shift
		;;
	esac
done

if [ -n "${STUB_LOG:-}" ]; then
	printf '%s\n' "fakesrc build.sh $ORIGINAL" >> "$STUB_LOG"
fi

[ -n "$OBJ" ] && [ -n "$MACHINE" ] || {
	printf 'fake-src-build.sh: -O and -m are required\n' >&2
	exit 1
}

SETS="$OBJ/releasedir/$MACHINE/binary/sets"
mkdir -p "$SETS"

# The METALOG of the upstream build: the metadata of the base system. The
# real build writes it into the destdir with "install -U -M"; it is the
# description of the modes and the owners of the base system, and it is
# what the image metadata is built from.
#
# The shape of the fixture is the shape of the real thing: the root first,
# then the directories, then the files under them, every entry with its
# mode, its size and its owner (and its digest, for a file). A fixture
# that holds three lines hides every ordering bug of the spec, because a
# spec built from it is short enough to be right by accident.
DEST="$OBJ/destdir.$MACHINE"
mkdir -p "$DEST"
cat > "$DEST/METALOG" <<'METALOG'
#mtree
. type=dir mode=0755 time=0.0 size=512 uname=root gname=wheel
./etc type=dir mode=0755 time=0.0 size=4096 uname=root gname=wheel
./etc/rc.d type=dir mode=0755 time=0.0 size=1024 uname=root gname=wheel
./etc/fstab type=file mode=0644 time=0.0 size=64 uname=root gname=wheel sha256=5b8f0c1d9a4e7b2c3d6f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5
./etc/motd type=file mode=0644 time=0.0 size=32 uname=root gname=wheel sha256=1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f809
./etc/myname type=file mode=0644 time=0.0 size=16 uname=root gname=wheel sha256=2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b
./etc/rc.conf type=file mode=0644 time=0.0 size=1024 uname=root gname=wheel sha256=3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c
./usr type=dir mode=0755 time=0.0 size=4096 uname=root gname=wheel
./usr/bin type=dir mode=0755 time=0.0 size=2048 uname=root gname=wheel
./usr/bin/su type=file mode=04555 time=0.0 size=16384 uname=root gname=wheel sha256=4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d
./usr/local type=dir mode=0755 time=0.0 size=512 uname=root gname=wheel
./tmp type=dir mode=01777 time=0.0 size=64 uname=root gname=wheel
METALOG

# The METALOG is written in the shape of the real one, and a test can
# change that shape: a METALOG without its "#mtree" header line, and a
# METALOG that holds a relative path. Both are shapes a build can find.
case ${FAKE_METALOG_NOHEADER:-0} in
1)
	grep -v '^#mtree$' "$DEST/METALOG" > "$DEST/METALOG.new" || true
	mv "$DEST/METALOG.new" "$DEST/METALOG"
	;;
esac
case ${FAKE_METALOG_RELATIVE:-0} in
1)
	printf '%s\n' '.. type=dir mode=0755 time=0.0 size=64 uname=root gname=wheel' \
		>> "$DEST/METALOG"
	;;
esac

if [ -n "${FAKE_SETS_DIR:-}" ] && [ -d "$FAKE_SETS_DIR" ]; then
	for t in "$FAKE_SETS_DIR"/*.tar.xz; do
		[ -f "$t" ] || continue
		cp "$t" "$SETS/"
	done
fi
