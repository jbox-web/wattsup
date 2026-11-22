//! `wattsup`: the state of the configured UPSes, in a terminal.

use std::path::PathBuf;
use std::process::ExitCode;
use std::thread;

use clap::{Parser, Subcommand};
use serde_json::json;
use wattsup_core::client::{list_ups, list_vars, Credentials, Endpoint, TIMEOUT};
use wattsup_core::config::{default_path, keychain_service, Config, UpsEntry, DEFAULT_PORT};
use wattsup_core::model::{Snapshot, State};

/// Exit status when a UPS is unreachable or has no data.
const EXIT_UNHEALTHY: u8 = 1;
/// Exit status on a usage or configuration error.
const EXIT_USAGE: u8 = 2;

#[derive(Parser)]
#[command(name = "wattsup", version, about = "State of UPSes served by NUT servers")]
struct Cli {
    /// Print JSON instead of text
    #[arg(long, global = true)]
    json: bool,
    /// Configuration file [default: ~/.config/wattsup/config.toml]
    #[arg(long, global = true, value_name = "PATH")]
    config: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// One line per configured UPS: state, charge, runtime, load
    Status,
    /// Every variable of one configured UPS, like `upsc`
    Vars {
        /// The display name of the UPS in the configuration
        name: String,
    },
    /// The UPS names a NUT server offers; needs no configuration
    List {
        /// host or host:port
        server: String,
    },
}

/// A failure with the exit status it maps to.
struct Failure {
    message: String,
    code: u8,
}

fn usage(message: impl Into<String>) -> Failure {
    Failure { message: message.into(), code: EXIT_USAGE }
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    let result = match &cli.command {
        Command::Status => status(&cli),
        Command::Vars { name } => vars(&cli, name),
        Command::List { server } => list(&cli, server),
    };
    match result {
        Ok(code) => ExitCode::from(code),
        Err(failure) => {
            eprintln!("wattsup: {}", failure.message);
            ExitCode::from(failure.code)
        }
    }
}

fn load(cli: &Cli) -> Result<Config, Failure> {
    let path = cli.config.clone().unwrap_or_else(default_path);
    Config::load(&path).map_err(|error| usage(error.to_string()))
}

fn status(cli: &Cli) -> Result<u8, Failure> {
    let config = load(cli)?;
    // One thread per UPS: an unreachable site must not delay the others.
    let polled: Vec<Result<Snapshot, Failure>> = thread::scope(|scope| {
        let handles: Vec<_> = config.ups.iter().map(|entry| scope.spawn(move || poll(entry))).collect();
        handles
            .into_iter()
            .map(|handle| handle.join().unwrap_or_else(|_| Err(usage("a poll thread panicked"))))
            .collect()
    });
    let mut snapshots = Vec::new();
    for (entry, snapshot) in config.ups.iter().zip(polled) {
        snapshots.push((entry, snapshot?));
    }

    if cli.json {
        let rows: Vec<_> =
            snapshots.iter().map(|(entry, snapshot)| snapshot_json(&entry.name, snapshot)).collect();
        println!("{}", serde_json::Value::Array(rows));
    } else if snapshots.is_empty() {
        eprintln!("wattsup: no UPS configured");
    } else {
        let mut rows = vec![["NAME", "STATE", "CHARGE", "RUNTIME", "LOAD"].map(String::from)];
        rows.extend(snapshots.iter().map(|(entry, snapshot)| status_row(&entry.name, snapshot)));
        print_table(&rows);
    }

    let unhealthy = snapshots
        .iter()
        .any(|(_, snapshot)| matches!(snapshot.state, State::Unreachable | State::NoData | State::Refused));
    Ok(if unhealthy { EXIT_UNHEALTHY } else { 0 })
}

fn vars(cli: &Cli, name: &str) -> Result<u8, Failure> {
    let config = load(cli)?;
    let entry = config
        .ups
        .iter()
        .find(|entry| entry.name.to_lowercase() == name.to_lowercase())
        .ok_or_else(|| usage(format!("no UPS named \"{name}\"")))?;
    let vars = list_vars(&endpoint(entry), &entry.ups, credentials(entry).as_ref(), TIMEOUT)
        .map_err(|error| Failure { message: format!("{}: {error}", entry.name), code: EXIT_UNHEALTHY })?;
    if cli.json {
        println!("{}", json!(vars));
    } else {
        for (name, value) in &vars {
            println!("{name}: {value}");
        }
    }
    Ok(0)
}

fn list(cli: &Cli, server: &str) -> Result<u8, Failure> {
    let (host, port) = parse_server(server).map_err(usage)?;
    let names = list_ups(&Endpoint { host, port }, TIMEOUT)
        .map_err(|error| Failure { message: format!("{server}: {error}"), code: EXIT_UNHEALTHY })?;
    if cli.json {
        let rows: Vec<_> = names
            .iter()
            .map(|(name, description)| json!({"name": name, "description": description}))
            .collect();
        println!("{}", serde_json::Value::Array(rows));
    } else {
        print_table(&names.into_iter().map(|(name, description)| [name, description]).collect::<Vec<_>>());
    }
    Ok(0)
}

fn endpoint(entry: &UpsEntry) -> Endpoint {
    Endpoint { host: entry.host.clone(), port: entry.port }
}

/// `host`, `host:port`, `[v6 address]:port`, or a bare IPv6 address (several colons, no port).
fn parse_server(server: &str) -> Result<(String, u16), String> {
    let invalid = || format!("invalid port in \"{server}\"");
    if let Some(rest) = server.strip_prefix('[') {
        let (host, after) = rest.split_once(']').ok_or_else(|| format!("missing ] in \"{server}\""))?;
        let port = match after.strip_prefix(':') {
            Some(port) => port.parse().map_err(|_| invalid())?,
            None if after.is_empty() => DEFAULT_PORT,
            None => return Err(invalid()),
        };
        return Ok((host.to_string(), port));
    }
    match server.split_once(':') {
        Some((host, port)) if !port.contains(':') => {
            Ok((host.to_string(), port.parse().map_err(|_| invalid())?))
        }
        _ => Ok((server.to_string(), DEFAULT_PORT)),
    }
}

fn poll(entry: &UpsEntry) -> Result<Snapshot, Failure> {
    let credentials = credentials(entry);
    Ok(match list_vars(&endpoint(entry), &entry.ups, credentials.as_ref(), TIMEOUT) {
        Ok(vars) => Snapshot::from_vars(vars),
        Err(error) => Snapshot::from_error(&error),
    })
}

/// The NUT credentials of an entry that has a username; the password comes from the Keychain.
/// The NUT credentials of an entry that has a username. Without a readable password the
/// UPS is polled without credentials, as the app does: the server then says whether it
/// needs them, and the other UPSes are not held back.
fn credentials(entry: &UpsEntry) -> Option<Credentials> {
    let username = entry.username.as_ref()?;
    match keychain_password(&keychain_service(&entry.name), username) {
        Some(password) => Some(Credentials { username: username.clone(), password }),
        None => {
            eprintln!(
                "wattsup: no password for \"{}\" in the Keychain: polled without credentials",
                entry.name
            );
            None
        }
    }
}

#[cfg(target_os = "macos")]
fn keychain_password(service: &str, account: &str) -> Option<String> {
    let bytes = security_framework::passwords::get_generic_password(service, account).ok()?;
    String::from_utf8(bytes).ok()
}

#[cfg(not(target_os = "macos"))]
fn keychain_password(_service: &str, _account: &str) -> Option<String> {
    None
}

fn state_label(state: State) -> &'static str {
    match state {
        State::OnMains => "on mains",
        State::OnBattery => "on battery",
        State::LowBattery => "low battery",
        State::Refused => "refused",
        State::NoData => "no data",
        State::Unreachable => "unreachable",
    }
}

fn state_key(state: State) -> &'static str {
    match state {
        State::OnMains => "on_mains",
        State::OnBattery => "on_battery",
        State::LowBattery => "low_battery",
        State::Refused => "refused",
        State::NoData => "no_data",
        State::Unreachable => "unreachable",
    }
}

fn status_row(name: &str, snapshot: &Snapshot) -> [String; 5] {
    let or_dash = |value: Option<String>| value.unwrap_or_else(|| "-".to_string());
    [
        name.to_string(),
        state_label(snapshot.state).to_string(),
        or_dash(snapshot.charge_percent.map(|charge| format!("{charge}%"))),
        or_dash(snapshot.runtime_seconds.map(runtime)),
        or_dash(snapshot.load_percent.map(|load| format!("{load}%"))),
    ]
}

/// `47m`, or `1h05m` from one hour up.
fn runtime(seconds: u32) -> String {
    let minutes = seconds / 60;
    if minutes < 60 {
        format!("{minutes}m")
    } else {
        format!("{}h{:02}m", minutes / 60, minutes % 60)
    }
}

fn snapshot_json(name: &str, snapshot: &Snapshot) -> serde_json::Value {
    json!({
        "name": name,
        "state": state_key(snapshot.state),
        "charge_percent": snapshot.charge_percent,
        "runtime_seconds": snapshot.runtime_seconds,
        "load_percent": snapshot.load_percent,
        "load_watts": snapshot.load_watts,
        "model": snapshot.model,
        "flags": snapshot.flags.all(),
        "error": snapshot.error,
        "vars": snapshot.vars,
    })
}

/// Prints rows with columns padded to the widest cell, two spaces apart.
fn print_table<const N: usize>(rows: &[[String; N]]) {
    let mut widths = [0; N];
    for row in rows {
        for (width, cell) in widths.iter_mut().zip(row) {
            *width = (*width).max(cell.chars().count());
        }
    }
    for row in rows {
        let line: Vec<String> =
            row.iter().zip(widths).map(|(cell, width)| format!("{cell:<width$}")).collect();
        println!("{}", line.join("  ").trim_end());
    }
}

#[cfg(test)]
mod tests {
    use super::parse_server;

    #[test]
    fn reads_every_form_of_server_address() {
        assert_eq!(parse_server("nas"), Ok(("nas".into(), 3493)));
        assert_eq!(parse_server("nas:3500"), Ok(("nas".into(), 3500)));
        assert_eq!(parse_server("192.0.2.10:3500"), Ok(("192.0.2.10".into(), 3500)));
        assert_eq!(parse_server("::1"), Ok(("::1".into(), 3493)));
        assert_eq!(parse_server("fe80::1:2"), Ok(("fe80::1:2".into(), 3493)));
        assert_eq!(parse_server("[::1]"), Ok(("::1".into(), 3493)));
        assert_eq!(parse_server("[::1]:3500"), Ok(("::1".into(), 3500)));
        assert!(parse_server("nas:port").is_err());
        assert!(parse_server("[::1]:x").is_err());
        assert!(parse_server("[::1").is_err());
    }
}
