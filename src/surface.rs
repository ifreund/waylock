use crate::env::LockEnv;

use cairo::{Context, ImageSurface};
use smithay_client_toolkit::{
    environment::Environment,
    reexports::{
        client::protocol::{wl_output, wl_shm, wl_surface},
        client::Main,
        protocols::wlr::unstable::layer_shell::v1::client::{
            zwlr_layer_shell_v1, zwlr_layer_surface_v1,
        },
    },
    shm::DoubleMemPool,
};
use std::{cell::Cell, rc::Rc};

#[derive(PartialEq, Copy, Clone)]
enum RenderEvent {
    Configure { width: u32, height: u32 },
    Close,
}

pub struct LockSurface {
    surface: wl_surface::WlSurface,
    _layer_surface: Main<zwlr_layer_surface_v1::ZwlrLayerSurfaceV1>,
    next_render_event: Rc<Cell<Option<RenderEvent>>>,
    pools: DoubleMemPool,
    dimensions: (u32, u32),
    redraw: bool,
    color: (f64, f64, f64),
}

impl LockSurface {
    pub fn new(
        output: &wl_output::WlOutput,
        lock_env: &Environment<LockEnv>,
        color: (f64, f64, f64),
    ) -> Self {
        let surface = lock_env.create_surface();
        let layer_surface = lock_env
            .require_global::<zwlr_layer_shell_v1::ZwlrLayerShellV1>()
            .get_layer_surface(
                &surface,
                Some(&output),
                zwlr_layer_shell_v1::Layer::Overlay,
                "lockscreen".to_owned(),
            );

        // TODO: set opaque region
        // Size of 0,0 indicates that the server should decide the size
        layer_surface.set_size(0, 0);
        // Anchor to all edges of the output, filling it entirely
        layer_surface.set_anchor(zwlr_layer_surface_v1::Anchor::all());
        layer_surface.set_exclusive_zone(-1);
        layer_surface.set_keyboard_interactivity(1);

        let next_render_event = Rc::new(Cell::new(None::<RenderEvent>));
        let next_render_event_handle = Rc::clone(&next_render_event);
        layer_surface.quick_assign(move |layer_surface, event, _| {
            match (event, next_render_event_handle.get()) {
                (zwlr_layer_surface_v1::Event::Closed, _) => {
                    next_render_event_handle.set(Some(RenderEvent::Close));
                }
                (
                    zwlr_layer_surface_v1::Event::Configure {
                        serial,
                        width,
                        height,
                    },
                    next,
                ) if next != Some(RenderEvent::Close) => {
                    layer_surface.ack_configure(serial);
                    next_render_event_handle.set(Some(RenderEvent::Configure { width, height }));
                }
                (_, _) => {}
            }
        });

        // Commit so that the server will send a configure event
        surface.commit();

        // TODO: this callback should technically trigger a redraw, however it is currently very
        // unlikely to be reached
        let pools = lock_env
            .create_double_pool(|_| {})
            .expect("ERROR: failed to create shm pools!");

        Self {
            surface,
            _layer_surface: layer_surface,
            next_render_event,
            pools,
            dimensions: (0, 0),
            redraw: false,
            color,
        }
    }

    /// Set the color of the surface. Will not take effect until handle_events() is called.
    pub fn set_color(&mut self, color: (f64, f64, f64)) {
        self.color = color;
        self.redraw = true
    }

    /// Handles any events that have occured since the last call, redrawing if needed.
    /// Returns true if the surface should be dropped.
    pub fn handle_events(&mut self) -> bool {
        match self.next_render_event.replace(None) {
            Some(RenderEvent::Close) => return true,
            Some(RenderEvent::Configure { width, height }) => {
                self.dimensions = (width, height);
                self.redraw = true;
            }
            None => {}
        }

        if self.redraw && self.try_redraw() {
            self.redraw = false;
        }
        false
    }

    fn try_redraw(&mut self) -> bool {
        if let Some(pool) = self.pools.pool() {
            let stride = 4 * self.dimensions.0 as i32;
            let width = self.dimensions.0 as i32;
            let height = self.dimensions.1 as i32;

            // First make sure the pool is large enough
            pool.resize((stride * height) as usize)
                .expect("ERROR: failed to resize shm pool");

            // Create a new buffer from the pool
            let buffer = pool.buffer(0, width, height, stride, wl_shm::Format::Argb8888);

            // Safety: the created cairo image surface and context go out of scope and are dropped as the
            // wl_surface is comitted. This means that the pool, which cannot be reused until the server
            // releases it, will be valid for the entire lifetime of the cairo context.
            let pool_data: &'static mut [u8] = unsafe {
                let mmap = pool.mmap();
                std::slice::from_raw_parts_mut(mmap.as_mut_ptr(), mmap.len())
            };
            let image_surface = ImageSurface::create_for_data(
                pool_data,
                cairo::Format::ARgb32,
                width,
                height,
                stride,
            )
            .expect("ERROR: failed to create cairo image surface!");
            let context = Context::new(&image_surface);

            context.set_operator(cairo::Operator::Source);
            context.set_source_rgb(self.color.0, self.color.1, self.color.2);
            context.paint();

            // Attach the buffer to the surface and mark the entire surface as damaged
            self.surface.attach(Some(&buffer), 0, 0);
            self.surface.damage_buffer(0, 0, width, height);

            // Finally, commit the surface
            self.surface.commit();
            true
        } else {
            false
        }
    }
}
