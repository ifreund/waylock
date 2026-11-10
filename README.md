# waylock

Waylock is a small screenlocker for Wayland compositors implementing
`ext-session-lock-v1`. The `ext-session-lock-v1` protocol is significantly
more robust than previous client-side Wayland screen locking approaches.
Importantly, the screenlocker crashing does not cause the session to be
unlocked.

Install from your [package manager](https://repology.org/project/waylock/versions)

The main repository is on [codeberg](https://codeberg.org/ifreund/waylock),
which is where the issue tracker may be found and where contributions are accepted.

Read-only mirrors exist on [sourcehut](https://git.sr.ht/~ifreund/waylock)
and [github](https://github.com/ifreund/waylock).

## Building

Note: If you are packaging waylock for distribution, see [PACKAGING.md](PACKAGING.md).

To compile waylock first ensure that you have the following dependencies
installed:

- [zig](https://ziglang.org/download/) 0.17.1
- wayland
- wayland-protocols
- xkbcommon
- pam
- pkg-config
- scdoc (optional, but required for man page generation)

Then run, for example:

```
zig build -Doptimize=ReleaseSafe --prefix /usr install
```

Note that the configuration file is installed to `$prefix/lib/pam.d`.
PAM searches the vendor directory `/usr/lib/pam.d` (or `/usr/local/lib/pam.d`
when installing with `--prefix /usr/local`) in addition to the administrator
override directory `/etc/pam.d`. Therefore care must be taken if installing
to a prefix other than `/usr` or `/usr/local` to ensure the configuration file
[pam.d/waylock](pam.d/waylock) is found by PAM.

## Usage

See the `waylock(1)` man page or the output of `waylock -h` for an overview
of the command line options.

Run the waylock executable to lock the session. All monitors will be blanked
with the `-init-color`. Typing causes the color to change to the
`-input-color`. `Esc` or `Ctrl-U` clears all current input, while `backspace`
deletes the last UTF-8 codepoint.

To unlock the session, type your password and press `Enter`. If the password
is correct, waylock will unlock the session and exit. Otherwise, the color
will change to the `-fail-color` and you may try again.

In order to automatically run waylock after a certain amount of time with no
input or before sleep, the [swayidle](https://github.com/swaywm/swayidle)
utility or a similar program may be used. See the `swayidle(1)` man page
for details.

## Licensing

Waylock is released under the ISC License.
