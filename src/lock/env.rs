use super::output::{LockOutputHandler, OutputHandling};

use smithay_client_toolkit::{
    environment,
    environment::{Environment, SimpleGlobal},
    reexports::{
        client::protocol::{wl_compositor, wl_output, wl_seat, wl_shm},
        client::{Attached, DispatchData, Display, EventQueue, Proxy},
        protocols::wlr::unstable::input_inhibitor::v1::client::zwlr_input_inhibit_manager_v1,
        protocols::wlr::unstable::layer_shell::v1::client::zwlr_layer_shell_v1,
    },
    seat::{SeatData, SeatHandler, SeatHandling, SeatListener},
    shm::ShmHandler,
};

use std::io;

pub struct LockEnv {
    compositor: SimpleGlobal<wl_compositor::WlCompositor>,
    layer_shell: SimpleGlobal<zwlr_layer_shell_v1::ZwlrLayerShellV1>,
    inhibitor_manager: SimpleGlobal<zwlr_input_inhibit_manager_v1::ZwlrInputInhibitManagerV1>,
    shm: ShmHandler,
    outputs: LockOutputHandler,
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

impl LockEnv {
    pub fn init_environment() -> io::Result<(Environment<Self>, Display, EventQueue)> {
        let display = Display::connect_to_env().unwrap_or_else(|err| {
            log::error!("Failed to connect to a wayland server: {}", err);
            panic!();
        });
        let mut queue = display.create_event_queue();
        let lock_env = Environment::new_pending(
            &Proxy::clone(&display).attach(queue.token()),
            LockEnv {
                compositor: SimpleGlobal::new(),
                layer_shell: SimpleGlobal::new(),
                inhibitor_manager: SimpleGlobal::new(),
                shm: ShmHandler::new(),
                outputs: LockOutputHandler::new(),
                seats: SeatHandler::new(),
            },
        );
        // Double roundtrip to ensure globals are bound.
        queue.sync_roundtrip(&mut (), |_, _, _| unreachable!())?;
        queue.sync_roundtrip(&mut (), |_, _, _| unreachable!())?;

        Ok((lock_env, display, queue))
    }

    pub fn set_output_created_listener<F: Fn(u32, wl_output::WlOutput) + 'static>(
        &mut self,
        listener: Option<F>,
    ) {
        self.outputs.set_created_listener(listener)
    }

    pub fn set_output_removed_listener<F: Fn(u32) + 'static>(&mut self, listener: Option<F>) {
        self.outputs.set_removed_listener(listener)
    }
}

impl OutputHandling for Environment<LockEnv> {
    fn set_output_created_listener<F: Fn(u32, wl_output::WlOutput) + 'static>(
        &self,
        listener: Option<F>,
    ) {
        self.with_inner(move |inner| inner.set_output_created_listener(listener))
    }

    fn set_output_removed_listener<F: Fn(u32) + 'static>(&self, listener: Option<F>) {
        self.with_inner(move |inner| inner.set_output_removed_listener(listener))
    }
}
