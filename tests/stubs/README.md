#!/bin/sh
# tests/stubs/README.md — what the stubs are for.
#
# Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
#
# `tests/stubs/bin/` holds tiny POSIX sh stand-ins for the tools the real
# build path calls: nbmakefs(1), nbgpt(8), nbinstallboot(8), nbpwd_mkdb(1),
# pkg_add(1), tar(1) and dd(1).
#
# Every stub appends its argv to $STUB_LOG (one line per call) and creates
# the output file it was asked to write. `tests/run-tests.sh` points the
# build at this directory with WTFBSD_TOOLDIR and runs the REAL build path
# (not the dry run) against a fake NetBSD source tree, so that a change
# in the build script is observable instead of only printed.
#
# The stubs never touch the machine they run on: they write into the
# temporary directory of the test and into $STUB_LOG.
#
# ## The options a stub accepts
#
# A stub that takes every option cannot catch a build that hands the real
# tool an option the manual page does not have: the stub would swallow it
# and the build host would refuse it hours later. Every stub therefore
# knows the options of its tool and refuses the others with
# "illegal option" and a non-zero exit status.
#
#   nbmakefs      makefs(8):      -B -b -d -F -f -M -m -N -O -o -R -S -s -T -t -x -Z
#   nbinstallboot installboot(8): -c -e -f -m -n -o -t -v
#   pkg_add       pkg_add(1):     -A -f -I -K -m -n -P -p -R -U -u -V -v
#   nbpwd_mkdb    pwd_mkdb(8):    -B -L -l -p -s -v -w -c -d -u -V
#   nbgpt         gpt(8):         the global options -r -v -s -p, and the
#                                subcommands create, add, show, label and
#                                destroy with their own options
#
# The global options of gpt(8) are marked as unverified in the round
# report: they come from the manual page, not from a run of the tool.
#
# `nbgpt create` never truncates the image: the image is written by dd(1)
# and the GPT is written into it.
#
# ## tests/stubs/rc.subr
#
# `tests/stubs/rc.subr` is a minimal stand-in for the NetBSD
# `/etc/rc.subr`. The rc.d scripts of this template use two of its
# functions: `load_rc_config` and `run_rc_command`.
#
# `run_rc_command` takes the command of the argument from the variable
# `${rc_arg}_cmd`: the variable `start_cmd` names the function that
# "start" runs. It never calls `<name>_start` by itself — a script that
# wants "start" to do something has to say so with `start_cmd`. That is
# the behaviour of the NetBSD rc.subr.
#
# The stub does not set PATH, does not override echo and printf and does
# not look for a running process: the test suite runs the stub tools from
# a temporary directory and needs them on the PATH.
#
# The rc.d script reads the path of the rc.subr it sources from the
# variable `firstboot_user_rcsubr`, so that the test suite can point it
# at this file.
