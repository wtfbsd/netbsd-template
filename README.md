# netbsd-template — NetBSD distribution template

A template for shipping a per-product distribution that is an **overlay on
unmodified upstream NetBSD**. Product name placeholders: **ExampleBSD**
(slug `examplebsd`), hostnames `example.org`. The template never patches
the NetBSD source tree and never patches pkgsrc; images are built with the
stock release tooling:

```
src/build.sh -U -m <machine> -O <obj> -T <tools> tools release   # the release sets
tar -xJf <obj>/releasedir/<machine>/binary/sets/*.tar.xz         # unpack them
pkg_add against a pkgsrc binary repository (PKG_PATH)            # the extra software
nbmakefs -t ffs + nbinstallboot + a GPT layout                    # the image
```

License: BSD-2-Clause (see `LICENSE`).

## Layout

```
.
├── AGENTS.md                   what this repository is, and how to work in it
├── Jenkinsfile                 CI: validate -> build -> boot test -> archive
├── opencode.json               the project's agents for opencode
├── build.sh                    the build driver (POSIX sh)
├── ci/
│   ├── vm.sh                   the one VM front end (create/console/addr/destroy)
│   └── providers/
│       └── bhyve.sh            the reference provider (stock FreeBSD bhyve(8))
├── overlay/                    THE overlay: nothing here patches src/ or pkgsrc
│   ├── base/
│   │   ├── packages.list       the pkgsrc packages every profile gets
│   │   └── rootfs/             copied over /: etc/motd.template, etc/myname,
│   │                           etc/fstab, etc/rc.conf.d/{ntpd,firstboot_user},
│   │                           etc/rc.d/firstboot_user,
│   │                           usr/local/sbin/@SLUG@-pool-create
│   └── profiles/
│       ├── appliance/          headless: packages.list, rc.conf.d/sshd, sshd_config
│       └── desktop/            X11 only: packages.list, rc.conf.d/{dbus,lightdm},
│                               the LightDM configuration
├── tests/
│   ├── run-tests.sh            the checks (no root, no network, no VM)
│   ├── boot-test.sh            boots an image and waits until it is usable
│   ├── stubs/                  stand-ins for the build tools: the tests run
│   │                           the REAL build path against them
│   └── fixtures/               the example product.conf, the canned serial log,
│                               the fake VM provider, the fake upstream build.sh
└── .opencode/agent/            the builder and tester agents
```

## Overlay rules

- **Never patch the NetBSD source tree and never patch pkgsrc.**
  Configuration happens through the files under `overlay/**/rootfs/`, which
  are copied over the staged root, and through `packages.list`, which
  names the pkgsrc packages that are installed into the stage.
- Overlay `rootfs` files are copied base-first, then the profile on top.
  The copy is a plain `cp -R`: the owner and the modes of this checkout
  never end up on the system directories of the image. `build.sh` sets the
  mode of every overlay file itself (0755 for the scripts, 0644 for
  everything else) and writes the owner, the group and the mode of every
  overlay file into the metadata spec of the image (the METALOG of the
  upstream build describes the base system).
- `@DISTRO_NAME@`, `@MOTD@`, `@SLUG@`, `@BRAND_URL@` and `@ZFS_POOL_NAME@`
  placeholders in the copied files are substituted by `build.sh` from
  `product.conf`. The substitution keeps the mode of the file it replaces.
- Files staged with a literal `@SLUG@` in their **name** (for example
  `usr/local/sbin/@SLUG@-pool-create`) are renamed by `build.sh` to the
  slug.
- `rc.conf.d` fragments are named **after their service**
  (`rc.conf.d/sshd`, `rc.conf.d/dbus`, ...): `rc(8)` only reads
  `/etc/rc.conf.d/<service-name>`, so a fragment named after the distro or
  the profile would never be read.
- A NetBSD rc variable is `<name>=YES` (`sshd=YES`, `ntpd=YES`,
  `lightdm=YES`): there is no `<name>_enable` on NetBSD.
- An rc.d script names the command of every action itself: the NetBSD
  `rc.subr` runs the function that `start_cmd` (and `stop_cmd`, ...)
  names and never calls `<name>_start` by itself. `etc/rc.d/firstboot_user`
  therefore sets `start_cmd="firstboot_user_start"`.
- `build.sh` sets `rc_configured="YES"` in the staged `/etc/rc.conf`,
  which is what makes `rc(8)` start the services at boot (see
  `rc.conf(5)`).
- The host name lives in `/etc/myname` (NetBSD keeps it there, not in an
  rc fragment), and `/etc/fstab` names the root filesystem by the label of
  its GPT partition (`<slug>root`).
- The stock release leaves root with an empty password; `build.sh` locks
  root in the staged image by writing `*` into the password field of
  `/etc/master.passwd` and rebuilding the password database with
  `nbpwd_mkdb`. The operator account is provisioned on the first boot
  (see **First-boot user** below).
- The desktop profile takes its whole X11 stack from pkgsrc, so the X
  sets of the release (`xbase`, `xcomp`, `xetc`, `xfont`, `xserver` —
  there is no `x11` set) are not unpacked into the image: the desktop has
  exactly one X11 in it. The desktop therefore needs the pkgsrc packages
  `xorg-server`, `xf86-input-libinput`, `xfce4`, `lightdm`,
  `lightdm-gtk-greeter` and `dbus`, and the fonts come from pkgsrc as
  well (`fontconfig`, `xfonts-base` and what the desktop asks for).
- Any `rm -rf` in `build.sh` is guarded: only paths that are validated
  non-empty and under the output directory may be removed. Edits such as
  the `rc_configured` change are applied to the STAGED copy only — the
  upstream tree is never touched.

## The wireless driver rule

The wireless driver that this template never enables is **never mentioned,
loaded or configured** here, and `build.sh` enforces that: the build fails
if any file under `overlay/` even mentions it — which is why the overlay
contains no such mention at all. Keep it that way.

## Profiles

| profile      | what it builds |
|--------------|----------------|
| `appliance`  | headless: a serial console, `sshd` with `PermitRootLogin no` and `PasswordAuthentication no`, no extra packages. The appliance also gets the ZFS data pool helper (`<slug>-pool-create`). |
| `desktop`    | X11 only, **no Wayland anywhere**: the Xorg server, Xfce and the LightDM greeter, all from pkgsrc, plus `dbus`. sshd is deliberately not enabled on the desktop. |

## The ZFS honesty rule

**NetBSD cannot boot from ZFS.** The root filesystem is FFS; ZFS is
available as a data pool only. `build.sh` refuses any
`FILESYSTEM_ROOT` other than `ffs` and says so, instead of building
something that cannot boot.

A product that wants ZFS therefore answers:

```
FILESYSTEM_ROOT=ffs
ZFS_DATA_POOL=yes
ZFS_POOL_NAME=exampledata
```

With that, `build.sh` enables the `zfs` service in `/etc/rc.conf.d/zfs`
(`zfs=YES`: the rc script loads the module and imports the pools). The
pool itself is **not** created at build time and **not** created at the
first boot: the disk it lives on is the operator's choice, so the helper
is run by hand, as root:

```
/usr/local/sbin/examplebsd-pool-create /dev/wd1d     # prints the plan only
/usr/local/sbin/examplebsd-pool-create --yes /dev/wd1d
```

The helper needs root and refuses a device that is not a good candidate:

- the disk that holds the running root is refused: the root wedge and the
  device are both resolved to their **parent disk** (`dkctl <dkN>
  getwedgeinfo` for a wedge), so every partition and every wedge of that
  disk is refused as well;
- a parent disk with a **GPT partition table** is refused (its wedges are
  its partitions), and the check runs on the parent disk, not on the
  device;
- a device whose **first mebibyte is not zero** is refused: it carries a
  label, a file system or something else. `disklabel(8)` is not asked for
  that — on a blank disk it prints a label of its own and exits with 0 —
  so the first mebibyte is read with `dd` and `od` instead;
- a pool that already exists is refused.

`--yes` is required before anything is created; `--force` (or `-f`) is a
separate, explicit flag: it skips the check of the first mebibyte (the
labels on the device are overwritten) and passes `-f` to `zpool create`.

## Packages

The extra software comes from pkgsrc. `packages.list` holds one pkgsrc
package name per line; `build.sh` installs the base list and the profile
list into the staged root with `pkg_add`:

```
PKG_PATH=https://<your pkgsrc binary repository>/ pkg_add -P <stage> <packages>
```

`pkg_add` runs with `PKG_RCD_SCRIPTS=YES`, so the rc.d scripts of the
packages are installed into `/etc/rc.d` of the stage, where `rc(8)`
finds them. `PKG_PATH` must point at a pkgsrc **binary** package
repository; a repository that was built for another architecture is
refused. The `pkg_install` package in `overlay/base/packages.list` is the
`pkg_add` tool itself and has to be bootstrapped first from that
repository. The pkgsrc prefix on NetBSD is `/usr/pkg`, which is where the
LightDM configuration of the desktop profile lives.

## Building

`product.conf` is produced by the answers script of the template set; its
keys are the question ids of the questions file. `build.sh` parses it
line by line and never sources it.

```sh
./build.sh -c product.conf -n                 # dry run: print the plan
./build.sh -c product.conf                    # the profile of product.conf
./build.sh -c product.conf -p both            # appliance + desktop
./build.sh -c product.conf -s /path/to/src    # another NetBSD source tree
```

The dry run validates the configuration, prints the whole plan and
changes nothing. The real build needs an unmodified NetBSD source tree
(only `src/build.sh` has to exist in it) and a host with `tar` (which
must handle xz) and a sha256 tool.

The build runs as an **ordinary user**: the owner, the group and the mode
of every file are written into a metadata spec that `nbmakefs(1)` reads
with `-F`, so no `chown(2)` is needed and the image is the same whoever
built it. The spec is the **METALOG of the upstream build**
(`$OBJ/destdir.$MACHINE/METALOG`), which describes the base system with
the modes the release really has — `/tmp` stays `01777` and `su` stays
`04555` — plus the entries of the files the build adds on top of it: the
overlay (with the modes of a declared table), the packages and the files
`build.sh` writes. The modes of the base system are never rebuilt from
the files of the build host: an unprivileged `tar` drops the setuid bits.
`nbmakefs` is called with `-N <stage>/etc`, so the user and the group
names of the image are resolved from the passwd and the group of the
target and never from the ones of the build host.

Knobs: `ROOTSIZE` (default `12G`), `ESPSIZE` (default `64m`), `DISKSIZE`
(default: the root plus the EFI partition plus slack), `PKG_PATH`,
`WTFBSD_TOOLDIR` (where `nbmakefs`, `nbgpt`, `nbinstallboot` and
`nbpwd_mkdb` are looked up; by default the tools directory of this build).

Artifacts:

```
out/<profile>/<slug>-<profile>-<arch>.img    the raw disk image
out/SHA256                                    its checksum
```

### The image layout

The image is a GPT disk with two partitions:

1. an EFI system partition (FAT, `64m`) holding the NetBSD EFI loader as
   `EFI/BOOT/BOOTX64.EFI` (`EFI/BOOT/BOOTAA64.EFI` on aarch64). The
   loader is the one of the release: `/usr/mdec/bootx64.efi` (on NetBSD
   `/boot` is the kernel, a file, not a directory);
2. the NetBSD FFS root filesystem, with the boot blocks installed by
   `nbinstallboot`. The image boots on a BIOS as well, through the boot
   block `bootxx_ffsv1` of the FFSv1 root.

The GPT labels are `<slug>esp` and `<slug>root`; `/etc/fstab` names the
root filesystem by the second one.

The exact flags of `nbmakefs`, `nbinstallboot` and `nbgpt` are listed as
unverified in the round report of the change that introduced them; they
are the parts of the build that were never run on real hardware from this
repository. The flags themselves are the ones of the manual pages now:
`nbmakefs` is called with `-t`, `-F`, `-N`, `-B`, `-s` and `-o` (the
`-U` of an earlier version is not an option of `makefs(8)` and is gone),
`nbinstallboot` with `-m`, and `nbgpt` with `create`, `add -t -s -i -l`
and `show -p`. The stubs of `tests/stubs/bin` refuse every option that
their manual page does not have, so a flag that does not exist is caught
by the test suite and not on the build host.

## First-boot user

Root is locked in the image, so the operator account is provisioned on the
first boot by `/etc/rc.d/firstboot_user` (enabled with
`firstboot_user=YES` in `/etc/rc.conf.d/firstboot_user`). NetBSD has no
KEYWORD `firstboot`, so the script runs once, guarded by a sentinel:
`build.sh` touches `/var/db/firstboot_user` into the image and the script
removes it when it is done.

It **parses** (never sources) `/etc/firstboot-user.conf` (`KEY=value`
lines):

```
USERNAME=alice        # ^[a-z_][a-z0-9_-]{0,31}$, required
FULLNAME=Alice        # no ':' / control characters, optional (default: username)
SSH_KEY=<a key line>  # one authorized_keys line, may repeat (at least one)
PASSWORD_HASH=$6$...  # crypt(3), $6$ or $2b$ only, optional ($6$|$2b$)
WHEEL=yes             # yes|no, default yes
```

The config is validated line by line, the user is created with
`useradd -m -s /bin/sh [-G wheel] -c FULLNAME USER` (NetBSD has no
`pw(8)`), a given hash is applied with `usermod -p HASH USER` (a locked
account cannot ssh, so without a hash the password stays `*` — key login
works — and the account is never locked), the keys are installed as
`~USER/.ssh/authorized_keys` (0700 dir / 0600 file, user-owned), and the
conf is renamed to `/etc/firstboot-user.conf.done` (chmod 600 — it may
contain a hash). Without a conf file the console gets instructions.

## CI

The `Jenkinsfile` is generic: no organisation names, no host names, no
credentials by value. Parameters:

| parameter | default | what it does |
|-----------|---------|--------------|
| `AGENT_LABEL` | `bsd` | the Jenkins agent that runs the pipeline — the default is a **placeholder**, the real label is the one of the site |
| `PROFILE` | `desktop`, `appliance`, `both` | which profile(s) to build |
| `BUILD_ON_AGENT` | `false` | build on the agent instead of in a build VM |
| `PRODUCT_CONF` | `product.conf` | the product configuration: it is uploaded as a file parameter of the File Parameter plugin, which stashes the file under the name of the parameter (not declared in the pipeline) |
| `PRODUCT_CONF_FILENAME` | `product.conf` | the name of the uploaded product configuration; the pipeline refuses a name that is not a plain file name |
| `VM_PROVIDER` | `bhyve` | the VM provider used for the build VM and the boot test |
| `BUILD_VM_NAME` | `wtfbsd-build` | the name of the build VM |
| `BUILD_VM_IMAGE` | empty | the disk image the build VM boots |
| `BUILD_VM_WORKDIR` | `wtfbsd-netbsd-template` | where the repository lives inside the build VM |

Stages: **Validate params** (checks the parameters and runs the dry run),
**Build** (in a build VM, or on the agent), **Boot test** (one
`tests/boot-test.sh` per profile), **Archive** (`out/**/*.img` and
`out/SHA256`). The `post` block always destroys the build VM.

`PRODUCT_CONF` is a **file parameter** of the **File Parameter plugin**,
so the plugin has to be installed on the Jenkins controller: the plugin
stashes the uploaded file under the name of the parameter, and the
pipeline takes it with `stashedFile('PRODUCT_CONF')` and
`unstash 'PRODUCT_CONF')` and copies it to `product.conf` with the
literal command `cp PRODUCT_CONF product.conf`. The upload parameter is
not declared in the `parameters` block of the pipeline: the legacy
`file(...)` parameter of the core uploads nothing, it points at a file on
the agent, and a parameter of the same name in the block would replace
the one of the plugin. The block declares `PRODUCT_CONF_FILENAME`
instead, the name of the uploaded file: the pipeline tests that the name
is a plain file name, and the value the plugin reports is
**unverified** — confirm it with one real upload. Without the plugin
the pipeline does not load.

Every VM of a build carries the name of the job and the number of the
build (`boot-appliance-my-job-42`), so that two builds of the same job
never share a name. The name of a VM and the slot of its devices are
written to a list in the workspace before the VM is created, and the
`post` block destroys every VM of the list with the slot it was created
with, whether the build succeeded or not. The list starts empty in every
build. The build VM is destroyed at the end of the Build stage, so that
the boot-test VMs never run next to it.

The null-modem pair and the tap of a VM follow the executor **and** the
slot of the VM in its job (`WTFBSD_VM_SLOT`: the build VM has the slot 0
and the boot-test VMs the slot 1), so that two VMs of one job never share
a device, and two jobs on one host never share one either.

Every free-text parameter that ends up in a remote command
(`CONF_PATH`, `PROFILE`, `BUILD_VM_WORKDIR`) is checked against
`^[A-Za-z0-9._/-]+$` before it is used, and it is quoted where it is
passed on. Every `ssh` and `scp` runs with `-o BatchMode=yes`,
`-o StrictHostKeyChecking=accept-new` and
`-o UserKnownHostsFile=<workspace file>`, so that a pipeline never
blocks on a password or on a host key prompt.

### VM providers

Every VM operation goes through `ci/vm.sh`, which dispatches on
`WTFBSD_VM_PROVIDER`:

```sh
ci/vm.sh create NAME IMAGE   # boot IMAGE as a VM called NAME
ci/vm.sh console NAME        # print the path of the serial console log
ci/vm.sh addr NAME           # print the address of the guest
ci/vm.sh destroy NAME        # stop the VM and remove its runtime state
```

The provider script is `ci/providers/<provider>.sh` from this repository.
A site with its own hypervisor points `WTFBSD_VM_PROVIDER_PATH` at a
provider script **outside** this repository; that file then replaces the
shipped one and receives the same subcommand and the same arguments:

```sh
WTFBSD_VM_PROVIDER=mysite WTFBSD_VM_PROVIDER_PATH=/opt/ci/my-provider.sh \
	ci/vm.sh create build-1 disk.img
```

An unknown provider, a missing `WTFBSD_VM_PROVIDER` and a missing provider
script all fail closed with a message on stderr.

The shipped reference provider is `ci/providers/bhyve.sh`: stock FreeBSD
`bhyve(8)` and `bhyvectl(8)` with the serial console logged through a
`nmdm(4)` device. It needs root on a FreeBSD host and these tools
there: `bhyve`, `bhyvectl`, `ifconfig`, `arp`.

#### The host of the reference provider

`bhyve(8)` is part of the base system: nothing has to be installed for
it. The UEFI firmware is not: it comes from the `edk2-bhyve` package,
which installs `/usr/local/share/uefi-firmware/BHYVE_UEFI.fd`. The
provider hands that file to `bhyve(8)` as a boot ROM (`-l bootrom`).

The guest gets a `tap(4)` device, and the provider attaches it to the
bridge of the host itself. The bridge is made once, on the host:

```sh
ifconfig bridge0 create
ifconfig bridge0 up
```

With `WTFBSD_BHYVE_BRIDGE=bridge0` the provider runs

```sh
ifconfig tap0 create
ifconfig tap0 up
ifconfig bridge0 addm tap0
```

when it creates the VM, and `ifconfig bridge0 deletem tap0` when it
destroys it. `ifconfig` on FreeBSD has no other keyword for the
interface a member hangs on: a member is added with `addm` and removed
with `deletem`.

The serial console is the null-modem pair `/dev/nmdmNA` and
`/dev/nmdmNB`: `bhyve(8)` writes to the A side, the provider reads the
B side. The reader puts its end of the device in raw mode without echo,
because the device opens in canonical mode with echo and the prompt of
`getty` has no newline: a canonical read never returns it, and echo
would feed the output of the guest back to it as input.

Two CI jobs on one host must not share a null-modem pair or a `tap`
device, so the unit of both follows `EXECUTOR_NUMBER` (the number of
the executor) and the slot of the VM: the unit is `executor * 2 + slot`,
and it is **not** wrapped in a modulo — `nmdm(4)` and `tap(4)` take any
unit number, and a unit that is taken by a modulo is a device that two
jobs share. `WTFBSD_BHYVE_NMDM` or `WTFBSD_BHYVE_TAP` say otherwise. The pid of the reader is written to
`$WTFBSD_BHYVE_CONSOLE/<name>.reader.pid`, and a reader of an earlier
run is killed before a new one is started: a reader that still holds
the null-modem open keeps the guest from writing anything.

#### The trust of a provider script

A provider script runs with the privileges of the Jenkins agent, and
the reference provider needs root to boot a guest. A provider script
from outside this repository is therefore code that the agent runs with
root: it must be **root-owned** and **not writable by the people who
write jobs**. Put it in a directory that only root can write to, and
point `WTFBSD_VM_PROVIDER_PATH` at it. The reference provider refuses
to run when it is not root.

### The boot test

```sh
tests/boot-test.sh out/appliance/examplebsd-appliance-amd64.img appliance
tests/boot-test.sh out/appliance/examplebsd-appliance-amd64.img appliance boot-appliance-my-job-42
```

It uses `ci/vm.sh` only, waits (600 seconds by default) for a `login:`
prompt on the serial console and, for the appliance profile, for `sshd`
to answer on port 22. The connect of the probe is bounded, so a host
that drops the packets cannot hold it open. It exits non-zero on a
timeout and always destroys the VM. `WTFBSD_BOOT_TIMEOUT` and
`WTFBSD_BOOT_SSH_PORT` change the timeout and the probed port.

The third argument is the name of the VM. The pipeline gives one, so
that it can destroy the VM again when the build fails; without it the
name is `boot-<profile>-<pid>`. A VM that cannot be destroyed is
reported on stderr, not swallowed.

## Running the tests

```sh
sh tests/run-tests.sh
```

The suite needs no root, no network and no VM. It runs the dry run of
`build.sh`, **the real build path** against a fake NetBSD source tree
with the tools of `tests/stubs` in their place (the stubs log every call,
so a change in the build script is observable and not only printed), it
checks the tree statically and it runs the boot test against the fake
provider in `tests/fixtures` (a script that publishes a canned serial
log). Every case is reported as `PASS` or `FAIL`; the exit status is
non-zero when a case failed.

The suite also refuses any file of this repository that carries an
internal shape: an address outside the loopback and the documentation
ranges, an email address outside `@example.org` and `@example.com`, an
internal top level domain, a key header, a token prefix or a credential
field name. The patterns are generic; a site that has its own names to
protect points `WTFBSD_DENYLIST` at a file with one regular expression
per line (the repository ships no such list, and none may be added to it).

## The generic-template rule

This repository is a **public, generic template**: anyone may fork it and
run it on their own Jenkins.

- No organisation-specific names anywhere: no company or project names
  other than `wtfbsd` and `ExampleBSD`, no real host names, no real
  addresses, no internal service names, no ticket numbers, no user names
  and no credential values. Credentials are referenced by a documented
  generic id only.
- The CI and the tests are generic: the VM handling goes through the one
  pluggable script `ci/vm.sh`, and a site plugs in its own provider with
  `WTFBSD_VM_PROVIDER_PATH`.
- The product is a placeholder: `ExampleBSD`, `examplebsd`,
  `example.org`. Replace them through `product.conf`.
