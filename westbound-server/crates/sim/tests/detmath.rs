//! DetMath parity (WP N8.2): the Rust port (`sim::detmath`) gives the GDScript `DetMath`'s
//! exact bits on every case of `vectors/detmath.json` (written by
//! tools/server_data/export_sim_data.gd, which runs `src/core/det_math.gd`). A NaN result
//! matches any NaN.

use serde_json::Value;
use sim::detmath;

fn hx(v: &Value) -> f64 {
    let s = v.as_str().expect("hex float");
    f64::from_bits(u64::from_str_radix(s, 16).expect("hex bits"))
}

fn call(name: &str, a: &[f64]) -> f64 {
    match name {
        "sin" => detmath::sin(a[0]),
        "cos" => detmath::cos(a[0]),
        "tan" => detmath::tan(a[0]),
        "atan" => detmath::atan(a[0]),
        "atan2" => detmath::atan2(a[0], a[1]),
        "asin" => detmath::asin(a[0]),
        "exp" => detmath::exp(a[0]),
        "log" => detmath::log(a[0]),
        "pow" => detmath::pow(a[0], a[1]),
        other => panic!("unknown function {other}"),
    }
}

#[test]
fn every_vector_bit_exact() {
    let d: Value = serde_json::from_str(include_str!("../vectors/detmath.json")).expect("json");
    let cases = d["cases"].as_array().expect("cases");
    assert!(cases.len() > 3000, "a few thousand cases");
    let mut bad = Vec::new();
    let mut per_fn = std::collections::BTreeMap::<String, usize>::new();
    for c in cases {
        let row = c.as_array().expect("row");
        let name = row[0].as_str().expect("name");
        let args: Vec<f64> = row[1..row.len() - 1].iter().map(hx).collect();
        let want = hx(&row[row.len() - 1]);
        let got = call(name, &args);
        *per_fn.entry(name.to_string()).or_default() += 1;
        if !(got.to_bits() == want.to_bits() || (got.is_nan() && want.is_nan())) {
            bad.push(format!(
                "{name}({args:?}) = {:016x}, gdscript {:016x}",
                got.to_bits(),
                want.to_bits()
            ));
        }
    }
    assert!(bad.is_empty(), "{} of {} differ:\n{}", bad.len(), cases.len(), bad[..bad.len().min(20)].join("\n"));
    for f in ["sin", "cos", "tan", "atan", "atan2", "asin", "exp", "log", "pow"] {
        assert!(per_fn.get(f).copied().unwrap_or(0) >= 300, "{f} covered");
    }
}

#[test]
fn sin_cos_is_sin_and_cos() {
    let d: Value = serde_json::from_str(include_str!("../vectors/detmath.json")).expect("json");
    for c in d["cases"].as_array().expect("cases") {
        let row = c.as_array().expect("row");
        if row[0].as_str() == Some("sin") {
            let x = hx(&row[1]);
            let (s, co) = detmath::sin_cos(x);
            assert!(s.to_bits() == detmath::sin(x).to_bits() || s.is_nan());
            assert!(co.to_bits() == detmath::cos(x).to_bits() || co.is_nan());
        }
    }
}
