//! What one poll of a UPS tells us.

use std::collections::{BTreeMap, BTreeSet};

use crate::client::ClientError;

/// The flags of `ups.status`, e.g. `OL CHRG`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StatusFlags(BTreeSet<String>);

/// Flags that only decide the state or describe the charge direction.
const CORE_FLAGS: [&str; 5] = ["OL", "OB", "LB", "CHRG", "DISCHRG"];

impl StatusFlags {
    pub fn parse(status: &str) -> StatusFlags {
        StatusFlags(status.split_whitespace().map(str::to_string).collect())
    }

    pub fn has(&self, flag: &str) -> bool {
        self.0.contains(flag)
    }

    /// Every flag, sorted.
    pub fn all(&self) -> Vec<String> {
        self.0.iter().cloned().collect()
    }

    /// The flags to show next to the state: everything but `OL`, `OB`, `LB`, `CHRG`, `DISCHRG`.
    pub fn extra(&self) -> Vec<String> {
        self.0.iter().filter(|flag| !CORE_FLAGS.contains(&flag.as_str())).cloned().collect()
    }
}

/// Ordered from worst to best.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum State {
    /// On battery and the UPS itself reports a low battery.
    LowBattery,
    OnBattery,
    /// The server answers but has nothing usable from the UPS.
    NoData,
    Unreachable,
    OnMains,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Snapshot {
    pub state: State,
    pub vars: BTreeMap<String, String>,
    pub flags: StatusFlags,
    pub charge_percent: Option<u8>,
    pub runtime_seconds: Option<u32>,
    pub load_percent: Option<u8>,
    pub load_watts: Option<u32>,
    pub model: Option<String>,
    /// Why there is no data, when the poll failed.
    pub error: Option<String>,
}

impl Snapshot {
    /// A variable that is missing or unusable is an absent field, never a zero.
    pub fn from_vars(vars: BTreeMap<String, String>) -> Snapshot {
        let flags = vars.get("ups.status").map(|status| StatusFlags::parse(status)).unwrap_or_default();
        let state = if flags.has("OB") {
            if flags.has("LB") {
                State::LowBattery
            } else {
                State::OnBattery
            }
        } else if flags.all().is_empty() {
            State::NoData
        } else {
            // On mains, or a status that says nothing about the supply (`OFF`, `BYPASS`...):
            // those flags are shown, they are not a failure.
            State::OnMains
        };
        let load_percent = percent(&vars, "ups.load");
        let nominal = number(&vars, "ups.realpower.nominal").filter(|watts| *watts > 0.0);
        let load_watts =
            load_percent.zip(nominal).map(|(load, watts)| (watts * f64::from(load) / 100.0).round() as u32);
        Snapshot {
            state,
            charge_percent: percent(&vars, "battery.charge"),
            runtime_seconds: number(&vars, "battery.runtime")
                .filter(|seconds| (0.0..=f64::from(u32::MAX)).contains(seconds))
                .map(|seconds| seconds.round() as u32),
            load_percent,
            load_watts,
            model: vars
                .get("device.model")
                .map(|model| model.trim().to_string())
                .filter(|model| !model.is_empty()),
            error: None,
            flags,
            vars,
        }
    }

    pub fn from_error(error: &ClientError) -> Snapshot {
        let state = match error {
            ClientError::Unreachable(_) => State::Unreachable,
            _ => State::NoData,
        };
        Snapshot {
            state,
            vars: BTreeMap::new(),
            flags: StatusFlags::default(),
            charge_percent: None,
            runtime_seconds: None,
            load_percent: None,
            load_watts: None,
            model: None,
            error: Some(error.to_string()),
        }
    }
}

/// The most serious of several states.
pub fn worst(states: &[State]) -> Option<State> {
    states.iter().min().copied()
}

fn number(vars: &BTreeMap<String, String>, name: &str) -> Option<f64> {
    vars.get(name)?.trim().parse::<f64>().ok().filter(|value| value.is_finite())
}

fn percent(vars: &BTreeMap<String, String>, name: &str) -> Option<u8> {
    number(vars, name).filter(|value| (0.0..=100.0).contains(value)).map(|value| value.round() as u8)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::ProtocolError;

    fn snapshot(vars: &[(&str, &str)]) -> Snapshot {
        Snapshot::from_vars(vars.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect())
    }

    #[test]
    fn derives_the_state_from_the_status_flags() {
        let cases: &[(&str, State, &[&str])] = &[
            ("OL", State::OnMains, &[]),
            ("OL CHRG", State::OnMains, &[]),
            ("OL LB", State::OnMains, &[]),
            ("OB DISCHRG", State::OnBattery, &[]),
            ("OB LB", State::LowBattery, &[]),
            ("OL RB", State::OnMains, &["RB"]),
            ("OB FSD", State::OnBattery, &["FSD"]),
        ];
        for (status, state, extra) in cases {
            let snap = snapshot(&[("ups.status", status)]);
            assert_eq!(snap.state, *state, "status {status}");
            assert_eq!(snap.flags.extra(), extra.to_vec(), "status {status}");
        }
    }

    #[test]
    fn a_missing_status_is_no_data() {
        assert_eq!(snapshot(&[("battery.charge", "100")]).state, State::NoData);
    }

    #[test]
    fn other_flags_alone_do_not_make_a_failure() {
        for status in ["OFF", "BYPASS", "CAL"] {
            let snap = snapshot(&[("ups.status", status), ("battery.charge", "100")]);
            assert_eq!(snap.state, State::OnMains, "status {status}");
            assert_eq!(snap.flags.extra(), [status], "status {status}");
            assert_eq!(snap.charge_percent, Some(100));
        }
    }

    #[test]
    fn an_empty_status_is_no_data() {
        assert_eq!(snapshot(&[("ups.status", "")]).state, State::NoData);
        assert_eq!(snapshot(&[("ups.status", "  ")]).state, State::NoData);
    }

    #[test]
    fn flags_are_queried_by_name() {
        let flags = StatusFlags::parse("OL  CHRG");
        assert!(flags.has("OL"));
        assert!(flags.has("CHRG"));
        assert!(!flags.has("OB"));
    }

    #[test]
    fn reads_the_charge() {
        assert_eq!(snapshot(&[("battery.charge", "100")]).charge_percent, Some(100));
        assert_eq!(snapshot(&[("battery.charge", "0")]).charge_percent, Some(0));
        assert_eq!(snapshot(&[("battery.charge", "99.6")]).charge_percent, Some(100));
    }

    #[test]
    fn an_unusable_charge_is_absent() {
        for value in ["abc", "150", "-1", "", "NaN"] {
            assert_eq!(snapshot(&[("battery.charge", value)]).charge_percent, None, "value {value:?}");
        }
        assert_eq!(snapshot(&[]).charge_percent, None);
    }

    #[test]
    fn reads_the_runtime() {
        assert_eq!(snapshot(&[("battery.runtime", "2858")]).runtime_seconds, Some(2858));
        assert_eq!(snapshot(&[("battery.runtime", "soon")]).runtime_seconds, None);
        assert_eq!(snapshot(&[]).runtime_seconds, None);
    }

    #[test]
    fn computes_the_load_in_watts_from_the_nominal_power() {
        let snap = snapshot(&[("ups.load", "10"), ("ups.realpower.nominal", "520")]);
        assert_eq!(snap.load_percent, Some(10));
        assert_eq!(snap.load_watts, Some(52));
    }

    #[test]
    fn has_no_watts_without_nominal_power() {
        let snap = snapshot(&[("ups.load", "10")]);
        assert_eq!(snap.load_percent, Some(10));
        assert_eq!(snap.load_watts, None);
    }

    #[test]
    fn trims_the_model() {
        assert_eq!(
            snapshot(&[("device.model", "Back-UPS BX950MI ")]).model.as_deref(),
            Some("Back-UPS BX950MI")
        );
        assert_eq!(snapshot(&[("device.model", "  ")]).model, None);
        assert_eq!(snapshot(&[]).model, None);
    }

    #[test]
    fn keeps_the_raw_variables() {
        let snap = snapshot(&[("ups.status", "OL"), ("input.voltage", "228.0")]);
        assert_eq!(snap.vars.get("input.voltage").map(String::as_str), Some("228.0"));
        assert_eq!(snap.error, None);
    }

    #[test]
    fn an_error_becomes_a_snapshot_without_variables() {
        let cases = [
            (ClientError::Unreachable("no answer within the timeout".into()), State::Unreachable),
            (ClientError::NoData("DATA-STALE".into()), State::NoData),
            (ClientError::Server("UNKNOWN-UPS".into()), State::NoData),
            (ClientError::Protocol(ProtocolError::UnterminatedQuote), State::NoData),
        ];
        for (error, state) in cases {
            let snap = Snapshot::from_error(&error);
            assert_eq!(snap.state, state);
            assert!(snap.vars.is_empty());
            assert_eq!(snap.charge_percent, None);
            assert_eq!(snap.error, Some(error.to_string()));
        }
    }

    #[test]
    fn worst_picks_the_most_serious_state() {
        assert_eq!(worst(&[State::OnMains, State::Unreachable, State::OnBattery]), Some(State::OnBattery));
        assert_eq!(worst(&[State::NoData, State::LowBattery, State::OnBattery]), Some(State::LowBattery));
        assert_eq!(worst(&[State::Unreachable, State::NoData]), Some(State::NoData));
        assert_eq!(worst(&[State::OnMains]), Some(State::OnMains));
        assert_eq!(worst(&[]), None);
    }
}
