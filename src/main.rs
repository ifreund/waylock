#[macro_use(environment)]
extern crate smithay_client_toolkit as sctk;

use sctk::environment::{Environment, SimpleGlobal};
use sctk::output::OutputHandler;
use sctk::reexports::calloop;
use sctk::reexports::client::protocol::{
    wl_compositor, wl_keyboard, wl_output, wl_seat, wl_shm, wl_surface,
};
use sctk::reexports::client::{Display, Proxy};
use sctk::reexports::protocols::wlr::unstable::{
    input_inhibitor::v1::client::zwlr_input_inhibit_manager_v1,
    layer_shell::v1::client::zwlr_layer_shell_v1,
};
use sctk::seat::keyboard::{map_keyboard, Event as KbEvent, RepeatKind};
use sctk::seat::SeatHandler;
use sctk::shm::ShmHandler;

use std::HashMap;

struct LockEnv {
    compositor: SimpleGlobal<wl_compositor::WlCompositor>,
    layer_shell: SimpleGlobal<zwlr_layer_shell_v1::ZwlrLayerShellV1>,
    inhibitor_manager: SimpleGlobal<zwlr_input_inhibit_manager_v1::ZwlrInputInhibitManagerV1>,
    shm: ShmHandler,
    outputs: OutputHandler,
    seats: SeatHandler,
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

fn main() {
    let (lock_env, display, queue) = {
        let display = Display::connect_to_env().unwrap();
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
        let ret = queue.sync_roundtrip(&mut (), |_, _, _| unreachable!());
        ret.and_then(|_| queue.sync_roundtrip(&mut (), |_, _, _| unreachable!()))
            .expect("Error during initial setup");

        (lock_env, display, queue)
    };

    let mut pools = lock_env
        .create_double_pool(|_| {})
        .expect("Failed to create a memory pool !");

    let mut seats = HashMap::new();
    let mut input = Vec::deque(

    // first process already existing seats
    for seat in lock_env.get_all_seats() {
        if let Some((has_kbd, name)) = sctk::seat::with_seat_data(&seat, |seat_data| {
            (
                seat_data.has_keyboard && !seat_data.defunct,
                seat_data.name.clone(),
            )
        }) {
            if has_kbd {
                let seat_name = name.clone();
                match map_keyboard(&seat, None, RepeatKind::System, move |event, _, _| {
                    print_keyboard_event(event, &seat_name)
                }) {
                    Ok((kbd, repeat_source)) => {
                        let source = event_loop
                            .handle()
                            .insert_source(repeat_source, |_, _| {})
                            .unwrap();
                        seats.insert(name, Some((kbd, source)));
                    }
                    Err(e) => {
                        eprintln!("Failed to map keyboard on seat {} : {:?}.", name, e);
                        seats.insert(name, None);
                    }
                }
            } else {
                seats.insert(name, None);
            }
        }
    }

    // then setup a listener for changes
    let loop_handle = event_loop.handle();
    let _seat_listener = lock_env.listen_for_seats(move |seat, seat_data, _| {
        seats
            .entry(&seat_data.name)
            .or_insert(None)
            .and_modify(|&mut opt_kbd| {
                // map a keyboard if the seat has the capability and is not defunct
                if seat_data.has_keyboard && !seat_data.defunct {
                    if opt_kbd.is_none() {
                        // initalize the keyboard
                        let seat_name = seat_data.name.clone();
                        match map_keyboard(&seat, None, RepeatKind::System, move |event, _, _| {
                            print_keyboard_event(event, &seat_name)
                        }) {
                            Ok((kbd, repeat_source)) => {
                                let source =
                                    loop_handle.insert_source(repeat_source, |_, _| {}).unwrap();
                                *opt_kbd = Some((kbd, source));
                            }
                            Err(e) => eprintln!(
                                "Failed to map keyboard on seat {} : {:?}.",
                                seat_data.name, e
                            ),
                        }
                    }
                } else {
                    if let Some((kbd, source)) = opt_kbd.take() {
                        // the keyboard has been removed, cleanup
                        kbd.release();
                        source.remove();
                    }
                }
            });
    });
}
