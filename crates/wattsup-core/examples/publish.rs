//! Reads one UPS and shows it in the macOS Batteries widget for a while.
//! Usage: publish <host> <ups> <seconds> [display name]

use std::time::Duration;

use wattsup_core::client::{list_vars, Endpoint, TIMEOUT};
use wattsup_core::model::Snapshot;
use wattsup_core::power_source::{details_for, Publisher};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let endpoint = Endpoint { host: args[1].clone(), port: 3493 };
    let snapshot = match list_vars(&endpoint, &args[2], None, TIMEOUT) {
        Ok(vars) => Snapshot::from_vars(vars),
        Err(error) => Snapshot::from_error(&error),
    };
    let name = args.get(4).cloned().or(snapshot.model.clone()).unwrap_or_else(|| args[2].clone());
    let details = details_for(&name, &snapshot);
    println!("{details:?}");
    let mut publisher = Publisher::new();
    publisher.set(&name, details.as_ref());
    println!("disabled: {}", publisher.is_disabled());
    std::thread::sleep(Duration::from_secs(args[3].parse().expect("seconds")));
}
