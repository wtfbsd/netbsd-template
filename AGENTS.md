# AGENTS.md — how to work in this repository

## What this repository is

`netbsd-template` is a **public, generic template** for shipping a
per-product NetBSD distribution. It builds images that are an **overlay on
unmodified upstream NetBSD**: the NetBSD source tree and pkgsrc are never
patched, the product is the set of files under `overlay/` plus the pkgsrc
packages it names.

Placeholders used everywhere: the product is **ExampleBSD**, its slug is
`examplebsd`, host names are `example.org`. The real values come from
`product.conf`, which is parsed, never sourced.

## The overlay rules

1. **Never patch the NetBSD source tree and never patch pkgsrc.**
   Everything a product needs is a file under `overlay/**/rootfs/` or a
   package name in a `packages.list`.
2. The overlay is copied base-first, then the profile on top of it.
3. Placeholders `@DISTRO_NAME@`, `@MOTD@`, `@SLUG@`, `@BRAND_URL@` and
   `@ZFS_POOL_NAME@` are substituted by `build.sh`; a staged file whose
   *name* contains `@SLUG@` is renamed to the slug.
4. `rc.conf.d` fragments are named after the service that reads them
   (`rc.conf.d/sshd`, `rc.conf.d/dbus`, ...). `rc(8)` reads only
   `/etc/rc.conf.d/<service-name>`. A NetBSD rc variable is `<name>=YES`;
   there is no `<name>_enable`. An rc.d script names the command of every
   action itself: the NetBSD `rc.subr` runs the function that `start_cmd`
   (and `stop_cmd`, ...) names and never calls `<name>_start` by itself.
5. `build.sh` sets `rc_configured="YES"` in the staged `/etc/rc.conf`;
   that is what makes `rc(8)` start the services.
6. Edits to a staged file (the `rc_configured` line, the root password)
   touch the staged copy only. The upstream tree is never modified.
7. Every `rm -rf` goes through the guarded `rmrf()` helper: the path must
   be non-empty and under the output directory.
8. The wireless driver this template never enables may not be mentioned
   anywhere in `overlay/`; `build.sh` fails the build if it is.
9. The overlay is copied without `cp -p`: the owner and the modes of the
   checkout never reach the image. `build.sh` sets the mode of every
   overlay file and writes the owner, the group and the mode of every
   overlay file into the metadata spec that `nbmakefs` reads with `-F`;
   the spec is the METALOG of the upstream build (it describes the base
   system) plus the entries of the files the build adds on top of it, and
   `nbmakefs` is called with `-N <stage>/etc`, so the names are resolved
   from the target. The build therefore needs no root.
10. The host name lives in `/etc/myname` and `/etc/fstab` names the root
    filesystem by the label of its GPT partition.

## The ZFS honesty rule

NetBSD cannot boot from ZFS. The root filesystem is FFS and ZFS is a data
pool only. `build.sh` refuses any other `FILESYSTEM_ROOT` and explains
the data-pool alternative. A product that wants ZFS answers:

```
FILESYSTEM_ROOT=ffs
ZFS_DATA_POOL=yes
ZFS_POOL_NAME=exampledata
```

`build.sh` then enables `zfs` in `/etc/rc.conf.d/zfs` and leaves the
creation of the pool to the operator: `<slug>-pool-create --yes DEVICE`
is run by hand, as root, and refuses the disk that holds the running
root.

## How to build

```sh
./build.sh -c product.conf -n     # dry run: validate and print the plan
./build.sh -c product.conf        # the real build
./build.sh -c product.conf -p both
```

The dry run changes nothing; always run it first. The real build needs an
unmodified NetBSD source tree (`src/build.sh` must exist in it) and a
`PKG_PATH` that points at a pkgsrc binary package repository.

## How to test

```sh
sh tests/run-tests.sh             # the whole suite, in the foreground
sh tests/boot-test.sh IMAGE PROFILE [NAME]   # boot an image and wait for it
```

The suite needs no root, no network and no VM. It runs the dry run of
`build.sh` **and the real build path**: the tools of `tests/stubs` stand
in for `nbmakefs`, `nbgpt`, `nbinstallboot`, `nbpwd_mkdb`, `pkg_add`,
`tar` and `dd`, they log every call, and the fake source tree in
`tests/fixtures` publishes the prepared release sets. A change in the
build script is therefore observable and not only printed.

The boot test uses `ci/vm.sh` only, waits for a `login:` prompt on the
serial console (and for `sshd` on the appliance profile), fails on a
timeout and always destroys the VM. The third argument is the name of
the VM: the pipeline gives one, so that it can destroy the VM again
when the build fails. A VM name is one short word; `ci/vm.sh` refuses a
name that is not, before it calls a provider.

## The generic-template rule

This repository ships to anyone, so it carries no organisation-specific
name, no real host name, no real address, no internal service name, no
ticket number, no user name and no credential value. Credentials are
referenced by a documented generic id only. The VM handling goes through
the one pluggable script `ci/vm.sh`; a site plugs in its own provider
with `WTFBSD_VM_PROVIDER_PATH` (a file outside this repository). An
unknown or missing provider must fail closed.

## The agents

`opencode.json` registers two agents, both of which read this file:

- `builder` — runs the dry run first, and the real build only when it is
  asked to; it never edits the overlay rules away.
- `tester` — runs `tests/run-tests.sh` in the foreground, reports red and
  green, and never weakens a test.

## Conventions

- POSIX `sh` (`#!/bin/sh`, `set -eu`), no bashisms, every expansion
  quoted, no `eval` on a configuration file, no global `IFS` change.
- Configuration files are parsed line by line (`KEY=value`), never
  sourced.
- Every new file starts with the license header:
  `Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).`
- Comments and documentation describe what the code does now, never what
  changed.
- Nothing outside the scope of the task is touched, and no git command
  that writes history or moves `HEAD` is run.
