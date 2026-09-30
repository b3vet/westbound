//! No allocations per tick in the traffic streaming path (N4.2; working rule 6, the N4.1
//! `sim/tests/alloc.rs` pattern): a rush-hour room with 8 players moving, one hit car and
//! the ramps churning steps its ring and writes all 8 clients' traffic into their reused
//! frame builders without allocating. A counting global allocator in this test binary
//! counts every allocation made on the test's thread while enabled.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::sync::atomic::{AtomicUsize, Ordering};

use protocol::{Density, FrameBuilder, RunState};
use westbound_server::rooms::road::lane_center_d_mm;
use westbound_server::rooms::sim_traffic::{SimTraffic, SimTrafficData};
use westbound_server::rooms::traffic::{PlayerView, RoomTraffic};
use westbound_server::rooms::RoomParams;
use westbound_server::Config;

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
fn streaming_a_rush_room_allocates_nothing() {
    let map = westbound_server::map::builtin()
        .expect("loop_v1")
        .map
        .clone();
    let data = SimTrafficData::builtin().expect("sim data");
    let params = RoomParams::from_config(&Config::default());
    let origin = 100;
    let mut t = SimTraffic::new(
        &data,
        &map,
        Density::Rush,
        5,
        origin,
        params.gap,
        params.stream,
    );
    let speeds = [60.0, 45.0, 33.0, 25.0, 70.0, 40.0, 28.0, 52.0];
    let mut s: Vec<f64> = (0..8).map(|k| 1_000.0 + 3_000.0 * k as f64).collect();
    let mut views: Vec<PlayerView> = Vec::with_capacity(8);
    let mut frames: Vec<FrameBuilder> = (0..8).map(|_| FrameBuilder::new()).collect();
    let mut now = origin;
    let mut bytes = 0usize;
    let mut run = |ticks: u32, now: &mut u32, first: bool| {
        for k in 0..ticks {
            *now += 1;
            views.clear();
            for p in 0..8 {
                s[p] = map.wrap_m(s[p] + speeds[p] * 0.05);
                let s_mm = map.wrap_mm((s[p] * 1_000.0).round() as i64);
                views.push(PlayerView {
                    player_id: p as u16 + 1,
                    tick: *now,
                    s_mm,
                    d_cm: (lane_center_d_mm(&map, (p % 2) as u8, s_mm) / 10) as i16,
                    speed_cms: (speeds[p] * 100.0) as u16,
                    heading_e4: 0,
                    lat_vel_cms: 0,
                    run_state: RunState::Driving,
                    protected_until: 0,
                });
            }
            t.tick(*now, &views);
            if k == 100 {
                // A hit: hazard and hard-brake intents, corrections every tick.
                let st = &t.world().sim.state;
                let slot = (0..st.capacity).find(|&i| st.active[i] == 1).unwrap_or(0);
                let car = t.stream().car_id(slot);
                assert!(t.notify_hit(1, car));
            }
            for (p, fb) in frames.iter_mut().enumerate() {
                fb.clear();
                let v = views[p];
                t.write_client(v.player_id, v.s_mm, first && k == 0, fb);
                bytes += fb.len();
            }
        }
    };
    // Warm up (joins allocate each client's buffers once), then count.
    run(100, &mut now, true);
    ALLOCS.store(0, Ordering::Relaxed);
    ON.with(|c| c.set(true));
    run(400, &mut now, false);
    ON.with(|c| c.set(false));
    let n = ALLOCS.load(Ordering::Relaxed);
    assert!(bytes > 0);
    assert_eq!(n, 0, "{n} allocations in 400 streamed ticks");
    assert!(t.stream().stats.hits >= 1);
}
