mod auth;
mod env;
mod input;
mod output;
mod surface;

use crate::options::Options;

use self::auth::LockAuth;
use self::env::LockEnv;
use self::input::LockInput;
use self::surface::LockSurface;

use smithay_client_toolkit::{
    reexports::{
        calloop,
        protocols::wlr::unstable::input_inhibitor::v1::client::zwlr_input_inhibit_manager_v1,
    },
    seat::keyboard::keysyms,
    WaylandSource,
};

pub fn lock_screen(options: &Options) -> std::io::Result<()> {
    let (lock_env, display, queue) = LockEnv::init_environment()?;

    let _inhibitor = lock_env
        .require_global::<zwlr_input_inhibit_manager_v1::ZwlrInputInhibitManagerV1>()
        .get_inhibitor();

    // TODO: Handle output hot plugging
    let mut lock_surfaces = lock_env
        .get_all_outputs()
        .iter()
        .map(|output| LockSurface::new(&output, &lock_env, options.color))
        .collect::<Vec<_>>();

    let mut event_loop = calloop::EventLoop::<()>::new()?;

    let lock_input = LockInput::new(&lock_env, event_loop.handle())?;

    let _source_queue =
        event_loop
            .handle()
            .insert_source(WaylandSource::new(queue), |ret, _| {
                if let Err(e) = ret {
                    panic!("Wayland connection lost: {:?}", e);
                }
            })?;

    let lock_auth = LockAuth::new();
    let mut current_password = String::new();

    loop {
        // Handle all input recieved since last check
        while let Some((keysym, utf8)) = lock_input.pop() {
            match keysym {
                keysyms::XKB_KEY_KP_Enter | keysyms::XKB_KEY_Return => {
                    if lock_auth.check_password(&current_password) {
                        return Ok(());
                    } else {
                        for lock_surface in lock_surfaces.iter_mut() {
                            lock_surface.set_color(options.fail_color);
                        }
                    }
                }
                keysyms::XKB_KEY_Delete | keysyms::XKB_KEY_BackSpace => {
                    current_password.pop();
                }
                keysyms::XKB_KEY_Escape => {
                    current_password.clear();
                }
                _ => {
                    if let Some(new_input) = utf8 {
                        current_password.push_str(&new_input);
                    }
                }
            }
        }

        // This is ugly, let's hope that some version of drain_filter() gets stablized soon
        // https://github.com/rust-lang/rust/issues/43244
        let mut i = 0;
        while i != lock_surfaces.len() {
            if lock_surfaces[i].handle_events() {
                lock_surfaces.remove(i);
            } else {
                i += 1;
            }
        }

        display.flush()?;
        event_loop.dispatch(None, &mut ())?;
    }
}
