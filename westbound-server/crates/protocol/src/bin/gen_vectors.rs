//! Writes the golden vectors to `crates/protocol/vectors/` (multiplayer handoff → Golden
//! vectors). Run: `cargo run -p protocol --bin gen_vectors`.

use std::path::Path;

fn main() -> std::io::Result<()> {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("vectors");
    let n = protocol::vectors::write_all(&dir)?;
    println!("wrote {n} vector files to {}", dir.display());
    Ok(())
}
