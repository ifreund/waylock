use super::env::LockEnv;

use smithay_client_toolkit::{
    environment::Environment,
    reexports::calloop,
    reexports::client::protocol::wl_keyboard,
    seat::{self, keyboard},
};
use std::{
    cell::RefCell,
    collections::{HashMap, VecDeque},
    rc::Rc,
};

pub struct LockInput {
    input_queue: Rc<RefCell<VecDeque<(u32, Option<String>)>>>,
}

impl LockInput {
    pub fn new(lock_env: &Environment<LockEnv>, loop_handle: calloop::LoopHandle<()>) -> Self {
        let input_queue = Rc::new(RefCell::new(VecDeque::new()));

        let mut seats: HashMap<
            String,
            Option<(
                wl_keyboard::WlKeyboard,
                calloop::Source<keyboard::RepeatSource>,
            )>,
        > = HashMap::new();

        let input_queue_handle = Rc::clone(&input_queue);
        let mut seat_handler = move |seat, seat_data: &seat::SeatData| {
            log::debug!("Handling seat '{}'", seat_data.name);
            let insert_seat = || {
                // map the keyboard, inserting an event handler
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
                        let source = loop_handle.insert_source(repeat_source, |_, _| {}).unwrap();
                        Some((kbd, source))
                    }
                    Err(err) => {
                        log::warn!(
                            "Ignoring seat {} due to failure to map keyboard: {:?}.",
                            seat_data.name,
                            err
                        );
                        None
                    }
                }
            };
            seats
                .entry(seat_data.name.clone())
                .and_modify(|kbd| {
                    // map a keyboard if the seat has the capability and is not defunct
                    if seat_data.has_keyboard && !seat_data.defunct && kbd.is_none() {
                        *kbd = insert_seat();
                    } else if let Some((kbd, source)) = kbd.take() {
                        // the keyboard has been removed, cleanup
                        kbd.release();
                        source.remove();
                    }
                })
                .or_insert_with(insert_seat);
        };

        // Process currently existing seats
        for seat in lock_env.get_all_seats() {
            if let Some(seat_data) = seat::with_seat_data(&seat, |seat_data| seat_data.clone()) {
                seat_handler(seat.clone(), &seat_data);
            }
        }

        // Setup a listener for changes
        let _seat_listener = lock_env.listen_for_seats(move |seat, seat_data, _| {
            seat_handler(seat, seat_data);
        });

        Self { input_queue }
    }

    pub fn pop(&self) -> Option<(u32, Option<String>)> {
        self.input_queue.borrow_mut().pop_front()
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
