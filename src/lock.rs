mod auth;
mod env;
mod input;
mod output;
mod surface;

use crate::options::Options;

use self::auth::LockAuth;
use self::env::LockEnv;
use self::input::LockInput;
use self::output::OutputHandling;
use self::surface::LockSurface;

use smithay_client_toolkit::{
    reexports::{
        calloop,
        client::protocol::{wl_compositor, wl_shm},
        protocols::wlr::unstable::input_inhibitor::v1::client::zwlr_input_inhibit_manager_v1,
        protocols::wlr::unstable::layer_shell::v1::client::zwlr_layer_shell_v1,
    },
    seat::keyboard::keysyms,
    WaylandSource,
};

use std::cell::RefCell;
use std::io;
use std::process::Command;
use std::rc::Rc;

#[derive(Copy, Clone)]
enum LockState {
    Init,
    Input,
    Fail,
}

pub fn lock_screen(options: &Options) -> io::Result<()> {
    let (lock_env, display, queue) = LockEnv::init_environment()?;

    let _inhibitor = lock_env
        .require_global::<zwlr_input_inhibit_manager_v1::ZwlrInputInhibitManagerV1>()
        .get_inhibitor();

    let lock_surfaces = {
        let compositor = lock_env.require_global::<wl_compositor::WlCompositor>();
        let layer_shell = lock_env.require_global::<zwlr_layer_shell_v1::ZwlrLayerShellV1>();
        let shm = lock_env.require_global::<wl_shm::WlShm>();
        let color = options.init_color;

        let lock_surfaces = Rc::new(RefCell::new(Vec::new()));

        let lock_surfaces_handle = Rc::clone(&lock_surfaces);
        lock_env.set_output_created_listener(Some(move |id, output| {
            (*lock_surfaces_handle.borrow_mut()).push((
                id,
                LockSurface::new(
                    &output,
                    &compositor.clone(),
                    &layer_shell.clone(),
                    shm.clone(),
                    color,
                ),
            ));
        }));

        let lock_surfaces_handle = Rc::clone(&lock_surfaces);
        lock_env.set_output_removed_listener(Some(move |id| {
            lock_surfaces_handle.borrow_mut().retain(|(i, _)| *i != id);
        }));

        lock_surfaces
    };

    let mut event_loop = calloop::EventLoop::<()>::try_new()?;

    let lock_input = LockInput::new(&lock_env, event_loop.handle());

    WaylandSource::new(queue).quick_insert(event_loop.handle())?;

    let lock_auth = LockAuth::new();
    let mut current_password = String::new();

    let mut lock_state = LockState::Init;

    let set_color = |color| {
        for (_, lock_surface) in lock_surfaces.borrow_mut().iter_mut() {
            lock_surface.set_color(color);
        }
    };

    loop {
        // Handle all input received since last check
        while let Some((keysym, utf8)) = lock_input.pop() {
            match keysym {
                keysyms::XKB_KEY_KP_Enter | keysyms::XKB_KEY_Return => {
                    if lock_auth.check_password(&current_password) {
                        return Ok(());
                    } else {
                        set_color(options.fail_color);
                        lock_state = LockState::Fail;

                        if let Some(command) = &options.fail_command {
                            if let Err(err) = Command::new("sh").arg("-c").arg(command).spawn() {
                                log::warn!("Error executing fail command \"{}\": {}", command, err);
                            }
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

            match (lock_state, current_password.is_empty()) {
                (LockState::Init, false) => {
                    set_color(options.input_color);
                    lock_state = LockState::Input;
                }
                (_, true) if !options.one_way => {
                    set_color(options.init_color);
                    lock_state = LockState::Init;
                }
                _ => {}
            }
        }

        // This is ugly, let's hope that some version of drain_filter() gets stabilized soon
        // https://github.com/rust-lang/rust/issues/43244
        {
            let mut lock_surfaces = lock_surfaces.borrow_mut();
            let mut i = 0;
            while i != lock_surfaces.len() {
                if lock_surfaces[i].1.handle_events() {
                    lock_surfaces.remove(i);
                } else {
                    i += 1;
                }
            }
        }

        retry_on_interrupt(|| display.flush())?;
        retry_on_interrupt(|| event_loop.dispatch(None, &mut ()))?;
    }
}

fn retry_on_interrupt<T, F: FnMut() -> io::Result<T>>(mut f: F) -> io::Result<T> {
    loop {
        match f() {
            Ok(val) => return Ok(val),
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        }
    }
}
