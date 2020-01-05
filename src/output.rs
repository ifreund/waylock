extern crate byteorder;
extern crate tempfile;

use wayland_client::protocol::{wl_buffer, wl_compositor, wl_shm, wl_shm_pool, wl_surface};
use wayland_client::{GlobalManager, Main};
use wayland_protocols::wlr::unstable::layer_shell::v1::client::{
    zwlr_layer_shell_v1, zwlr_layer_surface_v1,
};
//use wayland_protocols::unstable::xdg_output::v1::client::zxdg_output_manager_v1;

use byteorder::{NativeEndian, WriteBytesExt};
use std::fs::File;
use std::io::Write;
use std::os::unix::io::AsRawFd;
use std::cell::Cell;
use std::rc::Rc;

const WIDTH: i32 = 1920;
const HEIGHT: i32 = 1080;

pub struct Output {
    compositor: Main<wl_compositor::WlCompositor>,
    shm: Main<wl_shm::WlShm>,
    pub pool: Pool,
    pub surface: Main<wl_surface::WlSurface>,
    pub layer_surface: Main<zwlr_layer_surface_v1::ZwlrLayerSurfaceV1>,
}

impl Output {
    pub fn new(globals: &GlobalManager) -> Self {
        // Create the memory pool
        let shm = globals.instantiate_exact::<wl_shm::WlShm>(1).unwrap();
        let pool = Pool::new(&shm, WIDTH, HEIGHT);

        // Create the base surface for our locker
        let compositor = globals
            .instantiate_exact::<wl_compositor::WlCompositor>(4)
            .unwrap();
        let surface = compositor.create_surface();

        // Create the layer shell that tells the compositor how to display our surface
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

        // Configure the layer shell
        layer_surface.set_anchor(zwlr_layer_surface_v1::Anchor::all());
        // Indicate that the compositor should not move this surface to accommodate others and
        // instead extend it all the way to the anchors
        layer_surface.set_exclusive_zone(-1);
        // Request keyboard events to be sent
        // Only works if requested after the wl_seat has been created due to a bug in wlroots
        layer_surface.set_keyboard_interactivity(1);
        // commit our settings so that the server to send a configure so we can start drawing
        surface.commit();

        Self {
            compositor,
            shm,
            pool,
            surface,
            layer_surface,
        }
    }

    pub fn handle_event(&mut self, event: zwlr_layer_surface_v1::Event, locked: &Rc<Cell<bool>>) {
        match event {
            zwlr_layer_surface_v1::Event::Configure { serial, .. } => {
                // Tell the server we got its suggestions and will take them into account
                self.layer_surface.ack_configure(serial);
                self.layer_surface.set_keyboard_interactivity(1);
                // The coordinates passed are the upper left corner
                self.surface.attach(Some(&self.pool.base_buffer), 0, 0);
                // Mark the entire buffer as needing an update
                self.surface.damage(0, 0, WIDTH, HEIGHT);
                // Commit the pending buffer
                self.surface.commit();
                println!("committed a buffer!");
            }
            zwlr_layer_surface_v1::Event::Closed => {
                locked.set(false);
            }
            _ => unreachable!(),
        }
    }
}

pub struct Pool {
    pool_file: File,
    shm_pool: Main<wl_shm_pool::WlShmPool>,
    pub base_buffer: Main<wl_buffer::WlBuffer>,
    pub warn_buffer: Main<wl_buffer::WlBuffer>,
}

impl Pool {
    fn new(shm: &wl_shm::WlShm, width: i32, height: i32) -> Self {
        // Create a file to use as shared memory
        let mut pool_file = tempfile::tempfile().expect("Unable to create a tempfile.");
        // Write a nice color gradient to the file
        for _ in 0..(width * height) {
            // Solarized base03
            pool_file.write_u32::<NativeEndian>(0xFF002B36).unwrap();
        }
        for _ in 0..(width * height) {
            // Solarized red
            pool_file.write_u32::<NativeEndian>(0xFFDC322F).unwrap();
        }
        pool_file.flush().unwrap();

        // Use the wl_shm to create a pool
        let shm_pool = shm.create_pool(pool_file.as_raw_fd(), width * height * 4 * 2);

        // stride = height * 4 since each pixel is represented by 4 bytes in this format
        let base_buffer =
            shm_pool.create_buffer(0, width, height, width * 4, wl_shm::Format::Argb8888);
        let warn_buffer = shm_pool.create_buffer(
            width * height * 4,
            width,
            height,
            width * 4,
            wl_shm::Format::Argb8888,
        );

        Self {
            pool_file,
            shm_pool,
            base_buffer,
            warn_buffer,
        }
    }
}
