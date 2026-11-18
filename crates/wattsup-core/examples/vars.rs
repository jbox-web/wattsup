//! Prints every variable of one UPS as `name: value`, like `upsc`.
//! Usage: vars <host> <ups> [port]

use wattsup_core::client::{list_vars, Endpoint, TIMEOUT};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let port = args.get(3).map_or(3493, |p| p.parse().expect("port"));
    let endpoint = Endpoint { host: args[1].clone(), port };
    match list_vars(&endpoint, &args[2], None, TIMEOUT) {
        Ok(vars) => vars.iter().for_each(|(name, value)| println!("{name}: {value}")),
        Err(error) => {
            eprintln!("{error}");
            std::process::exit(1);
        }
    }
}
