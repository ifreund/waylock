# waylock

Waylock is a small screenlocker for Wayland compositors implementing
`ext-session-lock-v1`. The `ext-session-lock-v1` protocol is significantly
more robust than previous client-side Wayland screen locking approaches. In
particular, the screenlocker crashing does not cause the session to be
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

Then run, for example:

```
zig build -Drelease-safe --prefix /usr install
```

Note that PAM will only use configuration files in the system directory,
likely `/etc/pam.d` by default. Therefore care must be taken if
installing to a prefix other than `/usr` to ensure the configuration file
[pam.d/waylock](pam.d/waylock) is found by PAM.

## Usage

Run the waylock executable to lock the session. All monitors will be blanked
with a dark blue color. Typing causes the color to change to purple, to
clear what you've typed press Esc.

To unlock the session, type your password and press Enter. If the password
is correct, waylock will unlock the session and exit. Otherwise, the screen
will turn red and you may try again.

## Licensing

Waylock is released under the ISC License.
