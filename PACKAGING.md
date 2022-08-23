# Packaging waylock for distribution

First of all, I apologize for writing waylock in Zig. It will likely make
your job harder until Zig is more mature/stable. I do however believe that
writing my software in Zig allows me to deliver the best quality I can
despite the drawbacks of depending on a relatively immature language/toolchain.

*Note: At the time of writing there are to my knowledge no released versions
of wayland compositors implementing the ext-session-lock-v1 protocol waylock
requires. The next [river](https://github.com/riverwm/river) and
[sway](https://swaywm.org/) releases will support the protocol, expect them
to land shortly after wlroots 0.16.0. It is recommended to hold off on
packaging waylock 0.4.0 until after those releases land.*

## Source tarballs

Source tarballs with stable checksums and git submodule sources included may
be found on the [github releases](https://github.com/ifreund/waylock/releases)
page. These tarballs are signed with the PGP key available on my website at
<https://isaacfreund.com/public_key.txt>.

For the 0.4.0 release for example, the tarball and signature URLs are:
```
https://github.com/ifreund/waylock/releases/download/v0.4.0/waylock-0.4.0.tar.gz
https://github.com/ifreund/waylock/releases/download/v0.4.0/waylock-0.4.0.tar.gz.sig
```

## Zig version

Until Zig 1.0, Zig releases will often have breaking changes that prevent
waylock from building. Waylock tracks the latest minor version Zig release
and is only compatible with that release and any patch releases. At the time
of writing for example waylock is compatible with Zig 0.9.0 and 0.9.1 but
not Zig 0.8.0 or 0.10.0.

## Build options

Waylock is built using the Zig build system. To see all available build
options run `zig build --help`.

Important: By default Zig will build for the host system/cpu using the
equivalent of `-march=native`. To produce a portable binary `-Dcpu=baseline`
at a minimum must be passed.

Here are a few other options that are particularly relevant to packagers:

- `-Dcpu=baseline`: Build for the "baseline" CPU of the target architecture,
or any other CPU/feature set (e.g. `-Dcpu=x86_64_v2`).

  - Individual features can be added/removed with `+`/`-`
  (e.g. `-Dcpu=x86_64+avx2-cmov`).

  - For a list of CPUs see for example `zig targets | jq '.cpus.x86_64 |
  keys'`.

  - For a list of features see for example `zig targets | jq
  '.cpusFeatures.x86_64'`.

- `-Dtarget=x86_64-linux-gnu`: Target architecture, OS, and ABI triple. See
the output of `zig targets` for an exhaustive list of targets and CPU features,
use of `jq(1)` to inspect the output recommended.

- `-Dpie`: Build a position independent executable.

- `-Dstrip`: Build without debug info. This not the same as invoking `strip(1)`
on the resulting binary as it prevents the compiler from emitting debug info
in the first place. For greatest effect, both may be used.

- `--sysroot /path/to/sysroot`: Set the sysroot for cross compilation.

- `--libc my_libc.txt`: Set system libc paths for cross compilation. Run
`zig libc` to see a documented template for what this file should contain.

- Enable compiler optimizations:

  - `-Drelease-safe`: Keep all assertions and runtime safety checks active.

  - `-Drelease-fast`: Optimize for execution speed, disable all assertions
  and runtime safety checks.

  - `-Drelease-small`: Optimize for binary size, disable all assertions and
  runtime safety checks.

Please use `-Drelease-safe` when building waylock for general use. This
software is not at all demanding when it comes to CPU execution speed and the
increased safety is more than worth the binary size trade-off in my opinion.

## Build prefix and DESTDIR

To control the build prefix and directory use `--prefix` and the `DESTDIR`
environment variable. For example
```bash
DESTDIR="/foo/bar" zig build --prefix /usr install
```
will install waylock to `/foo/bar/usr/bin/waylock`.

The Zig build system only has a single install step, there is no way to build
artifacts for a given prefix and then install those artifacts to that prefix
at some later time. However, much existing distribution packaging tooling
expect separate build and install steps. To fit the Zig build system into this
tooling, I recommend the following pattern:

```bash
build() {
    DESTDIR="/tmp/waylock-destdir" zig build --prefix /usr install
}

install() {
    cp -r /tmp/waylock-destdir/* /desired/install/location
}
```

## Examples

Build for the host architecture and libc ABI:
```bash
DESTDIR=/foo/bar zig build -Drelease-safe -Dcpu=baseline \
    -Dstrip -Dpie --prefix /usr install
```

Cross compile for aarch64 musl libc based linux:
```bash
cat > xbps_zig_libc.txt <<-EOF
    include_dir=${XBPS_CROSS_BASE}/usr/include
    sys_include_dir=${XBPS_CROSS_BASE}/usr/include
    crt_dir=${XBPS_CROSS_BASE}/usr/lib
    msvc_lib_dir=
    kernel32_lib_dir=
    gcc_dir=
EOF

DESTDIR="/foo/bar" zig build \
    --sysroot "${XBPS_CROSS_BASE}" \
    --libc xbps_zig_libc.txt \
    -Dtarget=aarch64-linux-musl -Dcpu=baseline \
    -Drelease-safe -Dstrip -Dpie \
    --prefix /usr install
```

## Questions?

If you have any questions feel free to reach out to me at
`mail@isaacfreund.com` or in `#zig` or `#river` on `irc.libera.chat`, my
nick is `ifreund`.
