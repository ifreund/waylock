WAYLOCK(1) "github.com/ifreund/waylock" "General Commands Manual"

# NAME

waylock - a small Wayland screenocker

# SYNOPSIS

*waylock* [_options_]

# DESCRIPTION

Waylock is a small screenlocker for Wayland compositors implementing
*ext-session-lock-v1*. The *ext-session-lock-v1* protocol is significantly
more robust than previous client-side Wayland screen locking approaches.
Importantly, the screenlocker crashing does not cause the session to be
unlocked.

# OPTIONS

*-h*
	Print a help message and exit.

*-version*
	Print the version number and exit.

*-log-level* [*error*|*warning*|*info*|*debug*]
	Set the log level of waylock. At the *error* log level, only errors
	are logged.  At the *debug* log level, everything is logged including
	verbose debug messages.

*-init-color* _0xRRGGBB_
	Set the initial color. (default: 0x002b36)

*-input-color* _0xRRGGBB_
	Set the color used after input. (default: 0x6c71c4)

*-fail-color* _0xRRGGBB_
	Set the color used on authentication failure. (default: 0xdc322f)

# USAGE

Run the waylock executable to lock the session. All monitors will be
blanked with the *-init-color*. Typing causes the color to change to the
*-input-color*, to clear what you've typed press Esc or Ctrl-U.

To unlock the session, type your password and press Enter. If the password
is correct, waylock will unlock the session and exit. Otherwise, the color
will change to the *-fail-color* and you may try again.

To detach waylock from the controlling terminal to run as a daemon, *setsid*(1)
may be used.

# AUTHORS

Maintained by Isaac Freund <mail@isaacfreund.com> who is assisted by open
source contributors. For more information about waylock's development, see
https://github.com/ifreund/waylock.

# SEE ALSO

*pam*(8), *setsid*(1)
