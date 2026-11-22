//! The surface of `wattsup-core` the macOS app sees, through UniFFI.

use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;

use wattsup_core::client::{self, Credentials, Endpoint, TIMEOUT};
use wattsup_core::{changes, config, model, power_source};

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
#[uniffi(flat_error)]
pub enum CoreError {
    /// The configuration file cannot be read, parsed, validated or written.
    #[error("{0}")]
    Config(String),
    /// A server cannot be reached or refused the request.
    #[error("{0}")]
    Server(String),
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UpsEntry {
    pub name: String,
    pub host: String,
    pub port: u16,
    /// The UPS name on the NUT server.
    pub ups: String,
    pub publish: bool,
    pub notify_unreachable: bool,
    pub username: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Config {
    pub poll_interval_seconds: u32,
    pub ups: Vec<UpsEntry>,
}

/// A UPS offered by a server.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UpsName {
    pub name: String,
    pub description: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum State {
    LowBattery,
    OnBattery,
    Refused,
    NoData,
    Unreachable,
    OnMains,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Event {
    OnBattery,
    LowBattery,
    BackOnMains,
    Unreachable,
    ReachableAgain,
    NoData,
    Refused,
    ReplaceBattery,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Snapshot {
    pub state: State,
    pub vars: HashMap<String, String>,
    /// Every flag of `ups.status`, sorted.
    pub flags: Vec<String>,
    /// The flags worth showing next to the state (`RB`, `FSD`, ...).
    pub extra_flags: Vec<String>,
    pub charge_percent: Option<u8>,
    pub runtime_seconds: Option<u32>,
    pub load_percent: Option<u8>,
    pub load_watts: Option<u32>,
    pub model: Option<String>,
    pub error: Option<String>,
}

#[uniffi::export]
pub fn default_config_path() -> String {
    config::default_path().to_string_lossy().into_owned()
}

/// A missing file is an empty configuration.
#[uniffi::export]
pub fn load_config(path: String) -> Result<Config, CoreError> {
    config::Config::load(Path::new(&path))
        .map(Config::from)
        .map_err(|error| CoreError::Config(error.to_string()))
}

#[uniffi::export]
pub fn save_config(config: Config, path: String) -> Result<(), CoreError> {
    config::Config::from(config).save(Path::new(&path)).map_err(|error| CoreError::Config(error.to_string()))
}

/// The UPS names a server offers. Blocking.
#[uniffi::export]
pub fn list_ups(host: String, port: u16) -> Result<Vec<UpsName>, CoreError> {
    client::list_ups(&Endpoint { host, port }, TIMEOUT)
        .map(|names| names.into_iter().map(|(name, description)| UpsName { name, description }).collect())
        .map_err(|error| CoreError::Server(error.to_string()))
}

/// Polls one UPS. Blocking; a failure is a snapshot, never an error.
#[uniffi::export]
pub fn poll(entry: UpsEntry, password: Option<String>) -> Snapshot {
    let credentials =
        entry.username.clone().zip(password).map(|(username, password)| Credentials { username, password });
    let endpoint = Endpoint { host: entry.host, port: entry.port };
    match client::list_vars(&endpoint, &entry.ups, credentials.as_ref(), TIMEOUT) {
        Ok(vars) => model::Snapshot::from_vars(vars),
        Err(error) => model::Snapshot::from_error(&error),
    }
    .into()
}

/// The most serious of several states.
#[uniffi::export]
pub fn worst(states: Vec<State>) -> Option<State> {
    let states: Vec<model::State> = states.into_iter().map(model::State::from).collect();
    model::worst(&states).map(State::from)
}

/// The memory of one UPS between polls: turns snapshots into events.
#[derive(Default, uniffi::Object)]
pub struct Tracker(Mutex<changes::Tracker>);

#[uniffi::export]
impl Tracker {
    #[uniffi::constructor]
    pub fn new() -> Tracker {
        Tracker::default()
    }

    /// `mac_online` is false when the Mac has no network path or has just woken up.
    pub fn observe(&self, snapshot: Snapshot, mac_online: bool) -> Vec<Event> {
        let events = self.0.lock().unwrap().observe(&snapshot.into(), mac_online);
        events.into_iter().map(Event::from).collect()
    }

    /// The state to show; nil before the first poll and while the Mac itself is offline.
    pub fn displayed(&self) -> Option<State> {
        self.0.lock().unwrap().displayed().map(State::from)
    }
}

/// Shows UPSes in the macOS Batteries widget for as long as it lives.
#[derive(Default, uniffi::Object)]
pub struct Publisher(Mutex<power_source::Publisher>);

#[uniffi::export]
impl Publisher {
    #[uniffi::constructor]
    pub fn new() -> Publisher {
        Publisher::default()
    }

    /// Publishes or updates `name`; nil, or a snapshot without fresh data, withdraws it.
    pub fn set(&self, name: String, snapshot: Option<Snapshot>) {
        let details = snapshot.and_then(|snapshot| power_source::details_for(&name, &snapshot.into()));
        self.0.lock().unwrap().set(&name, details.as_ref());
    }

    /// True once macOS refused a call: the widget is not updated any more.
    pub fn is_disabled(&self) -> bool {
        self.0.lock().unwrap().is_disabled()
    }
}

impl From<config::UpsEntry> for UpsEntry {
    fn from(e: config::UpsEntry) -> UpsEntry {
        UpsEntry {
            name: e.name,
            host: e.host,
            port: e.port,
            ups: e.ups,
            publish: e.publish,
            notify_unreachable: e.notify_unreachable,
            username: e.username,
        }
    }
}

impl From<UpsEntry> for config::UpsEntry {
    fn from(e: UpsEntry) -> config::UpsEntry {
        config::UpsEntry {
            name: e.name,
            host: e.host,
            port: e.port,
            ups: e.ups,
            publish: e.publish,
            notify_unreachable: e.notify_unreachable,
            username: e.username,
        }
    }
}

impl From<config::Config> for Config {
    fn from(c: config::Config) -> Config {
        Config {
            poll_interval_seconds: c.poll_interval_seconds,
            ups: c.ups.into_iter().map(UpsEntry::from).collect(),
        }
    }
}

impl From<Config> for config::Config {
    fn from(c: Config) -> config::Config {
        config::Config {
            poll_interval_seconds: c.poll_interval_seconds,
            ups: c.ups.into_iter().map(config::UpsEntry::from).collect(),
        }
    }
}

impl From<model::State> for State {
    fn from(state: model::State) -> State {
        match state {
            model::State::LowBattery => State::LowBattery,
            model::State::OnBattery => State::OnBattery,
            model::State::Refused => State::Refused,
            model::State::NoData => State::NoData,
            model::State::Unreachable => State::Unreachable,
            model::State::OnMains => State::OnMains,
        }
    }
}

impl From<State> for model::State {
    fn from(state: State) -> model::State {
        match state {
            State::LowBattery => model::State::LowBattery,
            State::OnBattery => model::State::OnBattery,
            State::Refused => model::State::Refused,
            State::NoData => model::State::NoData,
            State::Unreachable => model::State::Unreachable,
            State::OnMains => model::State::OnMains,
        }
    }
}

impl From<changes::Event> for Event {
    fn from(event: changes::Event) -> Event {
        match event {
            changes::Event::OnBattery => Event::OnBattery,
            changes::Event::LowBattery => Event::LowBattery,
            changes::Event::BackOnMains => Event::BackOnMains,
            changes::Event::Unreachable => Event::Unreachable,
            changes::Event::ReachableAgain => Event::ReachableAgain,
            changes::Event::NoData => Event::NoData,
            changes::Event::Refused => Event::Refused,
            changes::Event::ReplaceBattery => Event::ReplaceBattery,
        }
    }
}

impl From<model::Snapshot> for Snapshot {
    fn from(s: model::Snapshot) -> Snapshot {
        Snapshot {
            state: s.state.into(),
            flags: s.flags.all(),
            extra_flags: s.flags.extra(),
            vars: s.vars.into_iter().collect(),
            charge_percent: s.charge_percent,
            runtime_seconds: s.runtime_seconds,
            load_percent: s.load_percent,
            load_watts: s.load_watts,
            model: s.model,
            error: s.error,
        }
    }
}

impl From<Snapshot> for model::Snapshot {
    fn from(s: Snapshot) -> model::Snapshot {
        model::Snapshot {
            state: s.state.into(),
            flags: model::StatusFlags::parse(&s.flags.join(" ")),
            vars: s.vars.into_iter().collect(),
            charge_percent: s.charge_percent,
            runtime_seconds: s.runtime_seconds,
            load_percent: s.load_percent,
            load_watts: s.load_watts,
            model: s.model,
            error: s.error,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn core_snapshot(status: &str) -> model::Snapshot {
        model::Snapshot::from_vars(
            [("ups.status", status), ("battery.charge", "90"), ("battery.runtime", "2858")]
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .into(),
        )
    }

    #[test]
    fn a_snapshot_survives_the_round_trip() {
        let original = core_snapshot("OB DISCHRG RB");
        let back: model::Snapshot = Snapshot::from(original.clone()).into();
        assert_eq!(back, original);
    }

    #[test]
    fn a_snapshot_exposes_its_extra_flags() {
        let snapshot = Snapshot::from(core_snapshot("OL CHRG RB"));
        assert_eq!(snapshot.flags, ["CHRG", "OL", "RB"]);
        assert_eq!(snapshot.extra_flags, ["RB"]);
    }

    #[test]
    fn the_tracker_reports_events_across_the_boundary() {
        let tracker = Tracker::new();
        assert_eq!(tracker.observe(core_snapshot("OL").into(), true), vec![]);
        assert_eq!(tracker.observe(core_snapshot("OB").into(), true), vec![Event::OnBattery]);
        assert_eq!(tracker.displayed(), Some(State::OnBattery));
    }

    #[test]
    fn worst_crosses_the_boundary() {
        assert_eq!(worst(vec![State::OnMains, State::Unreachable]), Some(State::Unreachable));
        assert_eq!(worst(vec![]), None);
    }

    #[test]
    fn poll_without_a_server_is_an_unreachable_snapshot() {
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let entry = UpsEntry {
            name: "x".into(),
            host: "127.0.0.1".into(),
            port,
            ups: "ups".into(),
            publish: false,
            notify_unreachable: true,
            username: None,
        };
        let snapshot = poll(entry, None);
        assert_eq!(snapshot.state, State::Unreachable);
        assert!(snapshot.vars.is_empty());
        assert!(snapshot.error.is_some());
    }

    #[test]
    fn a_configuration_survives_the_round_trip() {
        let dir = std::env::temp_dir().join(format!("wattsup-ffi-test-{}", std::process::id()));
        let path = dir.join("config.toml").to_string_lossy().into_owned();
        let entry = UpsEntry {
            name: "Maison".into(),
            host: "nas.example".into(),
            port: 3493,
            ups: "ups".into(),
            publish: true,
            notify_unreachable: false,
            username: Some("monuser".into()),
        };
        let original = Config { poll_interval_seconds: 45, ups: vec![entry] };
        save_config(original.clone(), path.clone()).unwrap();
        assert_eq!(load_config(path).unwrap(), original);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_invalid_configuration_is_a_config_error() {
        let invalid = Config { poll_interval_seconds: 1, ups: vec![] };
        let error = save_config(invalid, "/nonexistent/config.toml".into()).unwrap_err();
        assert!(matches!(error, CoreError::Config(_)));
    }
}
