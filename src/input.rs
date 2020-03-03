use crate::env::LockEnv;

use smithay_client_toolkit::{
    environment::Environment,
    reexports::calloop::LoopHandle,
    seat::{keyboard, with_seat_data},
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
    pub fn new(
        lock_env: &Environment<LockEnv>,
        loop_handle: LoopHandle<()>,
    ) -> std::io::Result<Self> {
        let mut seats = HashMap::new();
        let input_queue = Rc::new(RefCell::new(VecDeque::new()));

        // Process curently existing seats
        for seat in lock_env.get_all_seats() {
            if let Some((has_kbd, name)) = with_seat_data(&seat, |seat_data| {
                (
                    seat_data.has_keyboard && !seat_data.defunct,
                    seat_data.name.clone(),
                )
            }) {
                if has_kbd {
                    let input_queue_handle = input_queue.clone();
                    match keyboard::map_keyboard(
                        &seat,
                        None,
                        keyboard::RepeatKind::System,
                        move |event, _, _| {
                            handle_keyboard_event(event, Rc::clone(&input_queue_handle))
                        },
                    ) {
                        Ok((kbd, repeat_source)) => {
                            // Need to put the repeat_source in our event loop or key repitition won't
                            // work
                            let source = loop_handle.insert_source(repeat_source, |_, _| {})?;
                            seats.insert(name, Some((kbd, source)));
                        }
                        Err(e) => {
                            eprintln!(
                                "WARNING: Ignoring seat {} due to failure to map keyboard: {:?}.",
                                name, e
                            );
                            seats.insert(name, None);
                        }
                    }
                } else {
                    seats.insert(name, None);
                }
            }
        }

        // Setup a listener for changes
        let input_queue_handle = Rc::clone(&input_queue);
        let _seat_listener = lock_env.listen_for_seats(move |seat, seat_data, _| {
            seats
                .entry(seat_data.name.clone())
                .and_modify(|opt_kbd| {
                    // map a keyboard if the seat has the capability and is not defunct
                    if seat_data.has_keyboard && !seat_data.defunct {
                        if opt_kbd.is_none() {
                            // initalize the keyboard
                            let input_queue_handle_handle = Rc::clone(&input_queue_handle);
                            match keyboard::map_keyboard(
                                &seat,
                                None,
                                keyboard::RepeatKind::System,
                                move |event, _, _| {
                                    handle_keyboard_event(
                                        event,
                                        Rc::clone(&input_queue_handle_handle),
                                    )
                                },
                            ) {
                                Ok((kbd, repeat_source)) => {
                                    let source = loop_handle
                                        .insert_source(repeat_source, |_, _| {})
                                        .unwrap();
                                    *opt_kbd = Some((kbd, source));
                                }
                                Err(e) => eprintln!(
                                "WARNING: Ignoring seat {} due to failure to map keyboard: {:?}.",
                                seat_data.name, e
                            ),
                            }
                        }
                    } else if let Some((kbd, source)) = opt_kbd.take() {
                        // the keyboard has been removed, cleanup
                        kbd.release();
                        source.remove();
                    }
                })
                .or_insert(None);
        });
        Ok(Self { input_queue })
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
