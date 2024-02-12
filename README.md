# waylock

Waylock is a small screenlocker for Wayland compositors implementing
`ext-session-lock-v1`. The `ext-session-lock-v1` protocol is significantly
more robust than previous client-side Wayland screen locking approaches.
Importantly, the screenlocker crashing does not cause the session to be
unlocked.

The main repository is on [codeberg](https://codeberg.org/ifreund/waylock),
which is where the issue tracker may be found and where contributions are accepted.

Read-only mirrors exist on [sourcehut](https://git.sr.ht/~ifreund/waylock)
and [github](https://github.com/ifreund/waylock).

## Building

<a href="https://repology.org/project/waylock/versions">
    <img src="https://repology.org/badge/vertical-allrepos/waylock.svg" alt="Packaging status" align="right">
</a>

On cloning the repository, you must init and update the submodules as well
with e.g.

```
git submodule update --init
```

To compile waylock first ensure that you have the following dependencies
installed:

- [zig](https://ziglang.org/download/) 0.11.0
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

Note that PAM will only use configuration files in the system directory,
likely `/etc/pam.d` by default. Therefore care must be taken if
installing to a prefix other than `/usr` to ensure the configuration file
[pam.d/waylock](pam.d/waylock) is found by PAM.

If you are packaging waylock for distribution, see also
[PACKAGING.md](PACKAGING.md).

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
