mod surface;

use crate::surface::LockSurface;

use pam::Authenticator;
use smithay_client_toolkit::{
    environment,
    environment::{Environment, SimpleGlobal},
    output::OutputHandler,
    reexports::{
        calloop,
        client::protocol::{wl_compositor, wl_output, wl_seat, wl_shm},
        client::{Attached, DispatchData, Display, Proxy},
        protocols::wlr::unstable::{
            input_inhibitor::v1::client::zwlr_input_inhibit_manager_v1,
            layer_shell::v1::client::zwlr_layer_shell_v1,
        },
    },
    seat::{
        keyboard, keyboard::keysyms, with_seat_data, SeatData, SeatHandler, SeatHandling,
        SeatListener,
    },
    shm::ShmHandler,
    WaylandSource,
};
use std::{
    cell::RefCell,
    collections::{HashMap, VecDeque},
    rc::Rc,
};
use users::get_current_username;

pub struct LockEnv {
    compositor: SimpleGlobal<wl_compositor::WlCompositor>,
    layer_shell: SimpleGlobal<zwlr_layer_shell_v1::ZwlrLayerShellV1>,
    inhibitor_manager: SimpleGlobal<zwlr_input_inhibit_manager_v1::ZwlrInputInhibitManagerV1>,
    shm: ShmHandler,
    outputs: OutputHandler,
    seats: SeatHandler,
}

impl SeatHandling for LockEnv {
    fn listen<F: FnMut(Attached<wl_seat::WlSeat>, &SeatData, DispatchData) + 'static>(
        &mut self,
        f: F,
    ) -> SeatListener {
        self.seats.listen(f)
    }
}

environment!(LockEnv,
    singles = [
        wl_compositor::WlCompositor => compositor,
        zwlr_layer_shell_v1::ZwlrLayerShellV1 => layer_shell,
        zwlr_input_inhibit_manager_v1::ZwlrInputInhibitManagerV1 => inhibitor_manager,
        wl_shm::WlShm => shm,
    ],
    multis = [
        wl_output::WlOutput => outputs,
        wl_seat::WlSeat => seats,
    ]
);

// Solarized base03
const COLOR_NORMAL: (f64, f64, f64) = (
    0x00 as f64 / 255.0,
    0x2B as f64 / 255.0,
    0x36 as f64 / 255.0,
);

// Solarized red
const COLOR_INVALID: (f64, f64, f64) = (
    0xDC as f64 / 255.0,
    0x32 as f64 / 255.0,
    0x2F as f64 / 255.0,
);

fn main() -> std::io::Result<()> {
    let (lock_env, display, queue) = {
        let display =
            Display::connect_to_env().expect("ERROR: failed to connect to a wayland server!");
        let mut queue = display.create_event_queue();
        let lock_env = Environment::init(
            &Proxy::clone(&display).attach(queue.token()),
            LockEnv {
                compositor: SimpleGlobal::new(),
                layer_shell: SimpleGlobal::new(),
                inhibitor_manager: SimpleGlobal::new(),
                shm: ShmHandler::new(),
                outputs: OutputHandler::new(),
                seats: SeatHandler::new(),
            },
        );
        // Double roundtrip to ensure globals are bound.
        queue.sync_roundtrip(&mut (), |_, _, _| unreachable!())?;
        queue.sync_roundtrip(&mut (), |_, _, _| unreachable!())?;

        (lock_env, display, queue)
    };

    let _inhibitor = lock_env
        .require_global::<zwlr_input_inhibit_manager_v1::ZwlrInputInhibitManagerV1>()
        .get_inhibitor();

    // TODO: Handle output hot plugging
    let mut lock_surfaces = lock_env
        .get_all_outputs()
        .iter()
        .map(|output| LockSurface::new(&output, &lock_env, COLOR_NORMAL))
        .collect::<Vec<_>>();

    let mut seats = HashMap::new();
    let input_queue = Rc::new(RefCell::new(VecDeque::new()));
    let mut event_loop = calloop::EventLoop::<()>::new()?;

    // first process already existing seats
    for seat in lock_env.get_all_seats() {
        if let Some((has_kbd, name)) = with_seat_data(&seat, |seat_data| {
            (
                seat_data.has_keyboard && !seat_data.defunct,
                seat_data.name.clone(),
            )
        }) {
            if has_kbd {
                let input_queue_handle = input_queue.clone();
                match keyboard::map_keyboard(
                    &seat,
                    None,
                    keyboard::RepeatKind::System,
                    move |event, _, _| handle_keyboard_event(event, Rc::clone(&input_queue_handle)),
                ) {
                    Ok((kbd, repeat_source)) => {
                        // Need to put the repeat_source in our event loop or key repitition won't
                        // work
                        let source = event_loop
                            .handle()
                            .insert_source(repeat_source, |_, _| {})?;
                        seats.insert(name, Some((kbd, source)));
                    }
                    Err(e) => {
                        eprintln!(
                            "WARNING: Ignoring seat {} due to failure to map keyboard: {:?}.",
                            name, e
                        );
                        seats.insert(name, None);
                    }
                }
            } else {
                seats.insert(name, None);
            }
        }
    }

    // then setup a listener for changes
    let input_queue_handle = Rc::clone(&input_queue);
    let loop_handle = event_loop.handle();
    let _seat_listener = lock_env.listen_for_seats(move |seat, seat_data, _| {
        seats
            .entry(seat_data.name.clone())
            .and_modify(|opt_kbd| {
                // map a keyboard if the seat has the capability and is not defunct
                if seat_data.has_keyboard && !seat_data.defunct {
                    if opt_kbd.is_none() {
                        // initalize the keyboard
                        let input_queue_handle_handle = Rc::clone(&input_queue_handle);
                        match keyboard::map_keyboard(
                            &seat,
                            None,
                            keyboard::RepeatKind::System,
                            move |event, _, _| {
                                handle_keyboard_event(event, Rc::clone(&input_queue_handle_handle))
                            },
                        ) {
                            Ok((kbd, repeat_source)) => {
                                let source =
                                    loop_handle.insert_source(repeat_source, |_, _| {}).unwrap();
                                *opt_kbd = Some((kbd, source));
                            }
                            Err(e) => eprintln!(
                                "WARNING: Ignoring seat {} due to failure to map keyboard: {:?}.",
                                seat_data.name, e
                            ),
                        }
                    }
                } else if let Some((kbd, source)) = opt_kbd.take() {
                    // the keyboard has been removed, cleanup
                    kbd.release();
                    source.remove();
                }
            })
            .or_insert(None);
    });

    let _source_queue =
        event_loop
            .handle()
            .insert_source(WaylandSource::new(queue), |ret, _| {
                if let Err(e) = ret {
                    panic!("Wayland connection lost: {:?}", e);
                }
            })?;

    let current_username = get_current_username()
        .expect("ERROR: failed to get current username!")
        .into_string()
        .expect("ERROR: failed to parse current username!");
    let mut current_password = String::new();

    loop {
        // Handle all input recieved since last check
        while let Some((keysym, utf8)) = input_queue.borrow_mut().pop_front() {
            match keysym {
                keysyms::XKB_KEY_KP_Enter | keysyms::XKB_KEY_Return => {
                    if check_password(&current_username, &current_password) {
                        return Ok(());
                    } else {
                        for lock_surface in lock_surfaces.iter_mut() {
                            lock_surface.set_color(COLOR_INVALID);
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

fn handle_keyboard_event(
    event: keyboard::Event,
    input_queue_handle: Rc<RefCell<VecDeque<(u32, Option<String>)>>>,
) {
    match event {
        keyboard::Event::Key {
            keysym,
            state: keyboard::KeyState::Pressed,
            utf8,
            ..
        } => {
            input_queue_handle.borrow_mut().push_back((keysym, utf8));
        }
        _ => {}
    }
}

fn check_password(login: &str, password: &str) -> bool {
    let mut authenticator = Authenticator::with_password("system-auth")
        .expect("ERROR: failed to initialize PAM client!");
    authenticator.get_handler().set_credentials(login, password);
    match authenticator.authenticate() {
        Ok(()) => true,
        Err(error) => {
            eprintln!("WARNING: authentication failure {}", error);
            false
        }
    }
}
