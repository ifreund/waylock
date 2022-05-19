# waylock

Waylock is a small screenlocker for Wayland compositors implementing
`ext-session-lock-v1`. The `ext-session-lock-v1` protocol is significantly
more robust than previous client-side Wayland screen locking approaches.
Importantly, the screenlocker crashing does not cause the session to be
unlocked.

In addition, waylock has been entirely rewritten since version 0.3 for
security and simplicity. It now benefits from everything I've learned
about Wayland and programming in general over the past few years working on
[river](https://github.com/riverwm/river).

## Building

On cloning the repository, you must init and update the submodules as well
with e.g.

```
git submodule update --init
```

To compile waylock first ensure that you have the following dependencies
installed:

- [zig](https://ziglang.org/download/) 0.9
- wayland
- wayland-protocols
- xkbcommon
- pam
- pkg-config
- scdoc (optional, but required for man page generation)

Then run, for example:

```
zig build -Drelease-safe --prefix /usr install
```

Note that PAM will only use configuration files in the system directory,
likely `/etc/pam.d` by default. Therefore care must be taken if
installing to a prefix other than `/usr` to ensure the configuration file
[pam.d/waylock](pam.d/waylock) is found by PAM.

## Usage

See the `waylock(1)` man page or the output of `waylock -h` for an overview
of the command line options.

Run the waylock executable to lock the session. All monitors will be
blanked with the `-init-color`. Typing causes the color to change to the
`-input-color`, to clear what you've typed press `Esc` or `Ctrl-U`.

To unlock the session, type your password and press `Enter`. If the password
is correct, waylock will unlock the session and exit. Otherwise, the color
will change to the `-fail-color` and you may try again.

Detaching waylock from the controlling terminal to run as a daemon can be
accomplished with `setsid(1)`.

To detach waylock from the controlling terminal to run as a daemon, `setsid(1)`
may be used.

## Licensing

Waylock is released under the ISC License.
