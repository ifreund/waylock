use super::env::LockEnv;

use smithay_client_toolkit::{
    environment::Environment,
    reexports::calloop,
    reexports::client::protocol::{wl_keyboard, wl_pointer},
    seat::{self, keyboard},
};

use std::cell::RefCell;
use std::collections::VecDeque;
use std::rc::Rc;

type InputQueue = Rc<RefCell<VecDeque<(u32, Option<String>)>>>;

pub struct LockInput {
    input_queue: InputQueue,
    _seat_listener: seat::SeatListener,
}

struct LockSeat {
    name: String,
    keyboard: Option<(wl_keyboard::WlKeyboard, calloop::RegistrationToken)>,
    pointer: Option<wl_pointer::WlPointer>,
}

impl LockSeat {
    fn new(name: &str) -> Self {
        Self { name: name.to_owned(), keyboard: None, pointer: None }
    }
}

impl LockInput {
    pub fn new(lock_env: &Environment<LockEnv>, loop_handle: calloop::LoopHandle<'static, ()>) -> Self {
        let input_queue = Rc::new(RefCell::new(VecDeque::new()));

        let mut lock_seats: Vec<LockSeat> = Vec::new();

        let input_queue_handle = Rc::clone(&input_queue);
        let mut seat_handler = move |seat, seat_data: &seat::SeatData| {
            log::trace!("Handling seat '{}'", seat_data.name);

            // Find or insert a new seat
            let idx = lock_seats
                .iter()
                .position(|lock_seat| lock_seat.name == seat_data.name)
                .unwrap_or_else(|| {
                    lock_seats.push(LockSeat::new(&seat_data.name));
                    lock_seats.len() - 1
                });

            let lock_seat = &mut lock_seats[idx];

            if seat_data.has_keyboard && !seat_data.defunct {
                // If the seat has the keyboard capability and is not yet handled, initialize a handler.
                if lock_seat.keyboard.is_none() {
                    let input_queue_handle_handle = Rc::clone(&input_queue_handle);
                    match keyboard::map_keyboard_repeat(
                        loop_handle.clone(),
                        &seat,
                        None,
                        keyboard::RepeatKind::System,
                        move |event, _, _| handle_keyboard_event(event, &input_queue_handle_handle),
                    ) {
                        Ok((kbd, repeat_source)) => {
                            lock_seat.keyboard = Some((kbd, repeat_source));
                        }
                        Err(err) => log::error!(
                            "Failed to map seat '{}' keyboard: {:?}",
                            seat_data.name,
                            err
                        ),
                    }
                }
            } else if let Some((kbd, repeat_source)) = lock_seat.keyboard.take() {
                // If the seat has no keyboard capability but we have a keyboard stored, release it
                // as well as the repeat source if it exists.
                kbd.release();
                loop_handle.remove(repeat_source);
            }

            if seat_data.has_pointer && !seat_data.defunct {
                // If the seat has the pointer capability, create a handler to hide the cursor.
                if lock_seat.pointer.is_none() {
                    let pointer = seat.get_pointer();
                    pointer.quick_assign(|pointer, event, _| {
                        if let wl_pointer::Event::Enter { serial, .. } = event {
                            pointer.set_cursor(serial, None, 0, 0)
                        }
                    });
                    lock_seat.pointer = Some(pointer.detach());
                }
            } else if let Some(ptr) = lock_seat.pointer.take() {
                // If the seat has no pointer capability but we have a pointer stored, release it.
                ptr.release();
            }
        };

        // Process currently existing seats
        for seat in lock_env.get_all_seats() {
            if let Some(seat_data) = seat::with_seat_data(&seat, Clone::clone) {
                seat_handler(seat.clone(), &seat_data);
            }
        }

        // Setup a listener for changes
        let _seat_listener = lock_env.listen_for_seats(move |seat, seat_data, _| {
            seat_handler(seat, seat_data);
        });

        Self { input_queue, _seat_listener }
    }

    pub fn pop(&self) -> Option<(u32, Option<String>)> {
        self.input_queue.borrow_mut().pop_front()
    }
}

fn handle_keyboard_event(event: keyboard::Event, input_queue: &InputQueue) {
    match event {
        keyboard::Event::Key { keysym, state: keyboard::KeyState::Pressed, utf8, .. } => {
            input_queue.borrow_mut().push_back((keysym, utf8))
        }
        keyboard::Event::Repeat { keysym, utf8, .. } => {
            input_queue.borrow_mut().push_back((keysym, utf8));
        }
        _ => {}
    }
}
