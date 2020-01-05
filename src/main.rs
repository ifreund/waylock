extern crate byteorder;
extern crate tempfile;
#[macro_use(event_enum)]
extern crate wayland_client;
extern crate wayland_protocols;
extern crate xkbcommon;

pub mod input;
pub mod output;

use wayland_client::protocol::{wl_keyboard, wl_seat};
use wayland_client::{Display, EventQueue, Filter, GlobalManager};
use wayland_protocols::wlr::unstable::layer_shell::v1::client::zwlr_layer_surface_v1;

use std::cell::Cell;
use std::cell::RefCell;
use std::rc::Rc;

use crate::input::Input;
use crate::output::Output;

event_enum!(
    Events |
    Keyboard => wl_keyboard::WlKeyboard,
    LayerSurface => zwlr_layer_surface_v1::ZwlrLayerSurfaceV1
);

struct State {
    display: Display,
    event_queue: EventQueue,
    input_ref: Rc<RefCell<Input>>,
    output_ref: Rc<RefCell<Output>>,
    locked: Rc<Cell<bool>>,
}

impl State {
    pub fn new() -> Self {
        // Connect to the server
        let display = Display::connect_to_env().unwrap();
        let mut event_queue = display.create_event_queue();
        let attached_display = (*display).clone().attach(event_queue.get_token());
        // GlobalManager handles the registry for us
        let globals = GlobalManager::new(&attached_display);
        // Ensure the server has recieved our request and sent the globals
        event_queue.sync_roundtrip(|_, _| unreachable!()).unwrap();

        // Must instantiate the seat before the set_keyboard_interactivity request on the layer
        // surface for gaining focus to work due to a bug in wlroots
        let input = Input::new(&globals);
        let output = Output::new(&globals);

        Self {
            display,
            event_queue,
            input_ref: Rc::new(RefCell::new(input)),
            output_ref: Rc::new(RefCell::new(output)),
            locked: Rc::new(Cell::new(true)),
        }
    }
}

fn main() {
    let mut state = State::new();

    let output_ref = state.output_ref.clone();
    let input_ref = state.input_ref.clone();
    let locked = state.locked.clone();
    let common_filter = Filter::new(move |event, _| match event {
        Events::LayerSurface { event, .. } => output_ref.borrow_mut().handle_event(event, &locked),
        Events::Keyboard { event, .. } => input_ref.borrow_mut().handle_event(event, &locked),
    });

    state
        .output_ref
        .borrow_mut()
        .layer_surface
        .assign(common_filter.clone());

    let mut keyboard_created = false;
    state
        .input_ref
        .borrow_mut()
        .seat
        .assign_mono(move |seat, event| {
            if let wl_seat::Event::Capabilities { capabilities } = event {
                if !keyboard_created && capabilities.contains(wl_seat::Capability::Keyboard) {
                    // create the keyboard only once
                    keyboard_created = true;
                    seat.get_keyboard().assign(common_filter.clone());
                }
            }
        });

    while state.locked.get() {
        state.display.flush().unwrap();
        state
            .event_queue
            .dispatch(|_, _| { /* ignore unfiltered messages
                 TODO: error on unfiltered messages */
            })
            .expect("Error dispatching");
    }
}
