//! No allocations per tick (working rule 6; multiplayer plan §4: `sim` stays pure): a
//! full loop room ticking with players moving, reporting late, joining and leaving,
//! ramps and density upkeep running, allocates nothing. A counting global allocator in
//! this test binary counts every allocation made on the test's thread while enabled.

mod common;

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::sync::atomic::{AtomicUsize, Ordering};

use sim::traffic::sim::PlayerInput;
use sim::traffic::{Density, TrafficWorld};

struct Counting;

static ALLOCS: AtomicUsize = AtomicUsize::new(0);
thread_local! {
    static ON: Cell<bool> = const { Cell::new(false) };
}

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if ON.with(|c| c.get()) {
            ALLOCS.fetch_add(1, Ordering::Relaxed);
        }
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if ON.with(|c| c.get()) {
            ALLOCS.fetch_add(1, Ordering::Relaxed);
        }
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

#[test]
fn ticking_a_room_allocates_nothing() {
    let map = common::map();
    let mut world = TrafficWorld::builtin(&map, Density::Rush, 77).unwrap();
    world.set_density(Density::Normal); // exits run too
    let dt = world.dt();
    let mut s = [
        150.0, 3_000.0, 6_200.0, 9_000.0, 12_500.0, 16_100.0, 19_000.0, 22_500.0,
    ];
    // Warm up (first-use paths), then count.
    for round in 0..2 {
        if round == 1 {
            ALLOCS.store(0, Ordering::Relaxed);
            ON.with(|c| c.set(true));
        }
        for k in 0..600u32 {
            let now = world.tick_index();
            for (p, sp) in s.iter_mut().enumerate() {
                *sp = world.sim.road.wrap(*sp + 33.0 * dt);
                if p == 7 && k % 200 == 100 {
                    world.remove_player(p);
                    continue;
                }
                let lane = (p % 3) as i32;
                world.set_player(
                    p,
                    PlayerInput {
                        s: *sp,
                        d: world.sim.road.lane_center_d(lane, *sp),
                        s_dot: 33.0,
                        d_dot: if k % 90 < 30 { 0.8 } else { 0.0 },
                        length: 4.5,
                        width: 1.9,
                        tick: now.saturating_sub(3),
                    },
                );
            }
            if k == 300 {
                world.notify_hit(world.sim.order()[10].min(world.sim.state.capacity - 1), 2);
            }
            world.tick();
        }
        ON.with(|c| c.set(false));
    }
    let n = ALLOCS.load(Ordering::Relaxed);
    assert_eq!(n, 0, "{n} allocations in 600 ticks");
    assert!(world.sim.stat_signals > 0 && world.sim.stat_exits > 0);
}
