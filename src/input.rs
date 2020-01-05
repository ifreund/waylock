extern crate wayland_client;
extern crate wayland_protocols;
extern crate xkbcommon;

use wayland_client::protocol::{wl_keyboard, wl_seat};
use wayland_client::{GlobalManager, Main};
use wayland_protocols::wlr::unstable::input_inhibitor::v1::client::{
    zwlr_input_inhibit_manager_v1, zwlr_input_inhibitor_v1,
};
use xkbcommon::xkb;

use std::cell::Cell;
use std::rc::Rc;

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

    pub fn handle_event(&mut self, event: wl_keyboard::Event, locked: &Rc<Cell<bool>>) {
        match event {
            wl_keyboard::Event::Keymap { format, fd, size } => {
                if format != wl_keyboard::KeymapFormat::XkbV1 {
                    panic!("Unsupported keymap format, aborting");
                }
                self.xkb_keymap = Some(
                    xkb::Keymap::new_from_fd(
                        &self.xkb_context,
                        fd,
                        size as usize,
                        xkb::KEYMAP_FORMAT_TEXT_V1,
                        xkb::KEYMAP_COMPILE_NO_FLAGS,
                    )
                    .expect("Unable to create keymap"),
                );
                self.xkb_state = Some(xkb::State::new(self.xkb_keymap.as_ref().unwrap()));
            }
            wl_keyboard::Event::Key { key, state, .. } => {
                let keycode = if state == wl_keyboard::KeyState::Pressed {
                    key + 8
                } else {
                    0
                };
                let codepoint = self.xkb_state.as_ref().unwrap().key_get_utf32(keycode);
                if state == wl_keyboard::KeyState::Pressed {
                    println!("Key {} pressed", std::char::from_u32(codepoint).unwrap());
                    self.password
                        .push(std::char::from_u32(codepoint).expect("Invalid character codepoint"));
                    if self.password == "qwerty123" {
                        locked.set(false);
                    };
                }
            }
            wl_keyboard::Event::Modifiers {
                mods_depressed,
                mods_latched,
                mods_locked,
                group,
                ..
            } => {
                self.xkb_state.as_mut().unwrap().update_mask(
                    mods_depressed,
                    mods_latched,
                    mods_locked,
                    0,
                    0,
                    group,
                );
            }
            _ => {} // Don't care
        }
    }
}
