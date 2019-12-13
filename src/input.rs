extern crate wayland_client;
extern crate wayland_protocols;
extern crate xkbcommon;

use wayland_client::protocol::{wl_keyboard, wl_seat};
use wayland_client::{GlobalManager, Main};
use wayland_protocols::wlr::unstable::input_inhibitor::v1::client::{
    zwlr_input_inhibit_manager_v1, zwlr_input_inhibitor_v1,
};
use xkbcommon::xkb;

pub struct Input {
    pub seat: Main<wl_seat::WlSeat>,
    inhibitor: Main<zwlr_input_inhibitor_v1::ZwlrInputInhibitorV1>,
    pub xkb_context: xkb::Context,
    pub xkb_keymap: Option<xkb::Keymap>,
    pub xkb_state: Option<xkb::State>,
    pub password: String,
}

impl Input {
    pub fn new(globals: &GlobalManager) -> Self {
        // Get an instance of the InputInhibitorManager global with version 1
        let inhibitor_manager = globals
            .instantiate_exact::<zwlr_input_inhibit_manager_v1::ZwlrInputInhibitManagerV1>(1)
            .unwrap();
        // As long as the inhibitor has not been destroyed other clients receive no input
        let inhibitor = inhibitor_manager.get_inhibitor();

        let seat = globals.instantiate_exact::<wl_seat::WlSeat>(7).unwrap();
        let xkb_context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);

        Self {
            seat,
            inhibitor,
            xkb_context,
            xkb_keymap: None,
            xkb_state: None,
            password: String::new(),
        }
    }
}
