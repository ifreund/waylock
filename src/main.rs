extern crate byteorder;
extern crate tempfile;
#[macro_use(event_enum)]
extern crate wayland_client;
extern crate wayland_protocols;
extern crate xkbcommon;

use wayland_client::protocol::{wl_compositor, wl_keyboard, wl_seat, wl_shm, wl_surface};
use wayland_client::{Display, EventQueue, Filter, GlobalManager, Main};
use wayland_protocols::wlr::unstable::input_inhibitor::v1::client::{
    zwlr_input_inhibit_manager_v1, zwlr_input_inhibitor_v1,
};
use wayland_protocols::wlr::unstable::layer_shell::v1::client::{
    zwlr_layer_shell_v1, zwlr_layer_surface_v1,
};

use xkbcommon::xkb;
//use wayland_protocols::unstable::xdg_output::v1::client::zxdg_output_manager_v1;

use byteorder::{NativeEndian, WriteBytesExt};
use std::cell::Cell;
use std::io::Write;
use std::os::unix::io::AsRawFd;
use std::rc::Rc;

event_enum!(
    Events |
    Keyboard => wl_keyboard::WlKeyboard,
    LayerSurface => zwlr_layer_surface_v1::ZwlrLayerSurfaceV1
);

const WIDTH: i32 = 1920;
const HEIGHT: i32 = 1080;
// times 4 since each pixel is 4 bytes
const STRIDE: i32 = WIDTH * 4;

struct State {
    display: Display,
    event_queue: EventQueue,
    // inhibitor: Main<zwlr_input_inhibitor_v1::ZwlrInputInhibitorV1>,
    compositor: Main<wl_compositor::WlCompositor>,
    shm: Main<wl_shm::WlShm>,
    surface: Main<wl_surface::WlSurface>,
    layer_surface: Main<zwlr_layer_surface_v1::ZwlrLayerSurfaceV1>,
    seat: Main<wl_seat::WlSeat>,
    xkb_context: xkb::Context,
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

        // Get an instance of the InputInhibitorManager global with version 1
        //let inhibitor_manager = globals
        //    .instantiate_exact::<zwlr_input_inhibit_manager_v1::ZwlrInputInhibitManagerV1>(1)
        //    .unwrap();
        // As long as the inhibitor has not been destroyed other clients recieve no input
        // let inhibitor = inhibitor_manager.get_inhibitor();

        // Get an instance of the WlShm global with version 1
        let shm = globals.instantiate_exact::<wl_shm::WlShm>(1).unwrap();

        // Get an instance of the WlCompositor global with version 4
        let compositor = globals
            .instantiate_exact::<wl_compositor::WlCompositor>(4)
            .unwrap();
        // Have the compositor create a surface
        let surface = compositor.create_surface();
        // Get an instance of the wlr layer shell global with version 1
        let layer_shell = globals
            .instantiate_exact::<zwlr_layer_shell_v1::ZwlrLayerShellV1>(1)
            .unwrap();

        // TODO: support multiple monitors (The None passed means the compositor chooses one)
        let layer_surface = layer_shell.get_layer_surface(
            &surface,
            None,
            zwlr_layer_shell_v1::Layer::Overlay,
            "rslock".to_owned(),
        );

        layer_surface.set_size(0, 0);
        layer_surface.set_anchor(zwlr_layer_surface_v1::Anchor::all());
        // Indicate that the compositor should not move this surface to accomodate others and
        // instead extend it all the way to the anchors
        layer_surface.set_exclusive_zone(-1);
        // Request keyboard events to be sent
        layer_surface.set_keyboard_interactivity(1);
        // This call is quite important to get the server to send a configure so we can start
        // drawing
        surface.commit();

        let seat = globals.instantiate_exact::<wl_seat::WlSeat>(7).unwrap();

        let xkb_context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);

        Self {
            display,
            event_queue,
            // inhibitor,
            compositor,
            shm,
            surface,
            layer_surface,
            seat,
            xkb_context,
            locked: Rc::new(Cell::new(true)),
        }
    }
}

fn main() {
    // let inhibitor = ZwlrInputInhibitManagerV1::get_inhibitor();
    let mut state = State::new();

    // Create a file to use as shared memory
    let mut pool_file = tempfile::tempfile().expect("Unable to create a tempfile.");
    // Write a nice color gradient to the file
    for _ in 0..(WIDTH * HEIGHT) {
        pool_file.write_u32::<NativeEndian>(0xFF002B36).unwrap();
    }
    pool_file.flush().unwrap();

    // Use the wl_shm to create a pool
    let shm_pool = state
        .shm
        .create_pool(pool_file.as_raw_fd(), WIDTH * HEIGHT * 4);
    // Create a buffer that we can later attach to a surface
    let buffer = shm_pool.create_buffer(0, WIDTH, HEIGHT, STRIDE, wl_shm::Format::Argb8888);

    let surface = state.surface.clone();
    let locked = state.locked.clone();
    let common_filter = Filter::new(move |event, _| match event {
        Events::LayerSurface {
            event,
            object: layer_surface,
        } => match event {
            zwlr_layer_surface_v1::Event::Configure { serial, .. } => {
                // Tell the server we got its suggestions and will take them into account
                layer_surface.ack_configure(serial);
                layer_surface.set_keyboard_interactivity(1);
                // The coordinates passed are the upper left corner
                surface.attach(Some(&buffer), 0, 0);
                // Mark the entire buffer as needing an update
                surface.damage(0, 0, WIDTH, HEIGHT);
                // Commit the pending buffer
                surface.commit();
                println!("committed a buffer!");
            }
            zwlr_layer_surface_v1::Event::Closed => {
                locked.set(false);
            }
            _ => unreachable!(),
        },
        Events::Keyboard { event, .. } => match event {
            wl_keyboard::Event::Enter { .. } => {
                println!("Gained keyboard focus.");
            }
            wl_keyboard::Event::Leave { .. } => {
                println!("Lost keyboard focus.");
            }
            wl_keyboard::Event::Key { key, state, .. } => {
                println!("Key with id {} was {:?}.", key, state);
                locked.set(false);
            }
            _ => {}
        },
    });
    state.layer_surface.assign(common_filter.clone());

    let mut keyboard_created = false;
    state.seat.assign_mono(move |seat, event| {
        if let wl_seat::Event::Capabilities { capabilities } = event {
            if !keyboard_created && capabilities.contains(wl_seat::Capability::Keyboard) {
                // create the keyboard only once
                keyboard_created = true;
                seat.get_keyboard().assign(common_filter.clone());
            }
        }
    });

    state
        .event_queue
        .sync_roundtrip(|_, _| { /* ignore unfiltered messages */ })
        .unwrap();
    while state.locked.get() {
        state.display.flush().unwrap();
        state
            .event_queue
            .dispatch(|_, _| { /* ignore unfiltered messages */ })
            .expect("Error dispatching");
    }
}
