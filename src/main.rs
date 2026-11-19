// Issue #1246: a panic in production is a silent availability incident.
#![deny(clippy::unwrap_used, clippy::expect_used)]

//! Soroban Pulse entry point. All wiring lives in `soroban_pulse::app` (#1346).

use soroban_pulse::app::{self, AppBuilder};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    app::init_telemetry()?;
    let app = AppBuilder::new().build().await?;
    app.serve().await?;
    app::shutdown_telemetry();
    Ok(())
}
