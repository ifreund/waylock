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
        ret.and_then(|_| queue.sync_roundtrip(&mut (), |_, _, _| unreachable!())).expect("Error during initial setup");
        
        (lock_env, display, queue)
    };
}
