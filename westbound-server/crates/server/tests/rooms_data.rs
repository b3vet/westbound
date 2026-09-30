//! "Data shared with the client comes from the client" (multiplayer handoff → Rules for the
//! server code, rule 5): the `[rooms]` defaults that mirror the game's tuning must equal
//! it. Reads the Godot project's `data/` (the repository root, three levels up from this
//! crate): the room clock from `data/tuning/loop.tres`, the car limits from
//! `data/cars/*.tres` and `data/tuning/vehicle.tres`.

use std::path::{Path, PathBuf};

use westbound_server::Config;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..")
}

/// `key = value` of a `.tres` file's `[resource]` section, as a number.
fn tres_number(path: &Path, key: &str) -> f64 {
    let text =
        std::fs::read_to_string(path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    text.lines()
        .find_map(|l| {
            let (k, v) = l.split_once(" = ")?;
            (k.trim() == key).then(|| v.trim().parse::<f64>().ok())?
        })
        .unwrap_or_else(|| panic!("{key} in {}", path.display()))
}

#[test]
fn the_room_clock_is_the_games() {
    let loop_tres = repo_root().join("data/tuning/loop.tres");
    let r = Config::default().rooms;
    let min_ms = 60_000.0;
    assert_eq!(
        f64::from(r.cycle_len_ms),
        tres_number(&loop_tres, "room_cycle_min") * min_ms
    );
    assert_eq!(
        f64::from(r.day_len_ms),
        tres_number(&loop_tres, "room_day_min") * min_ms
    );
    assert_eq!(
        r.clock_epoch_unix_ms as f64,
        tres_number(&loop_tres, "room_clock_epoch_unix_s") * 1_000.0
    );
}

#[test]
fn the_car_limits_are_the_games() {
    let root = repo_root();
    let mut top = 0.0f64;
    for e in std::fs::read_dir(root.join("data/cars")).expect("data/cars") {
        let p = e.expect("entry").path();
        if p.extension().is_some_and(|x| x == "tres") {
            top = top.max(tres_number(&p, "top_speed_kmh"));
        }
    }
    let vehicle = root.join("data/tuning/vehicle.tres");
    let boost_pct = tres_number(&vehicle, "boost_top_speed_bonus_pct");
    let r = Config::default().rooms;
    assert!(
        (r.max_speed_kmh - top * (1.0 + boost_pct / 100.0)).abs() < 1e-9,
        "rooms.max_speed_kmh {} vs the fastest car {top} km/h + {boost_pct} % boost",
        r.max_speed_kmh
    );
    let accel = tres_number(&vehicle, "engine_traction_max_mps2")
        + tres_number(&vehicle, "boost_thrust_mps2");
    assert_eq!(r.max_accel_mps2, accel);
    // A lane change's peak lateral speed (a smooth 3.6 m move in the shortest time, peak
    // 1.875 × average) stays under the lateral cap.
    let lane_m = tres_number(&vehicle, "lane_change_distance_m");
    let text = std::fs::read_to_string(&vehicle).unwrap();
    let fastest_s = text
        .lines()
        .find_map(|l| l.strip_prefix("lane_change_times_s = PackedFloat64Array("))
        .and_then(|l| l.trim_end_matches(')').split(',').next())
        .and_then(|v| v.trim().parse::<f64>().ok())
        .expect("lane_change_times_s");
    let peak = 1.875 * lane_m / fastest_s;
    assert!(peak < r.max_lateral_speed_mps, "{peak}");
}
