//! Publishes a UPS to macOS as a power source, so that it shows in Apple's Batteries widget.
//!
//! This relies on private IOKit functions (`IOPowerSourcesPrivate.h` in Apple's open-source
//! IOKitUser). They may stop working with a macOS update: every failure here is contained.

use crate::model::{Snapshot, State};

/// Published as an accessory, not as a UPS: a source of type `UPS` reporting `Battery Power`
/// makes macOS believe the Mac itself runs on that UPS and switch to its battery energy
/// settings (measured on macOS 27.2). An accessory source leaves the Mac untouched.
const PS_TYPE: &str = "Accessory Source";
const PS_TRANSPORT: &str = "USB";
/// The Batteries widget draws an icon only for a known accessory category; there is none
/// for a UPS. "Battery Case" gives a small plug.
const PS_CATEGORY: &str = "Battery Case";

/// What is shown for one UPS.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceDetails {
    pub name: String,
    pub charge_percent: u8,
    pub on_battery: bool,
    pub charging: bool,
    pub minutes_to_empty: Option<u32>,
}

/// A value of the published dictionary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    Text(String),
    Flag(bool),
    Number(i32),
}

/// `None` when there is nothing trustworthy to show: no fresh data, or no charge.
pub fn details_for(name: &str, snapshot: &Snapshot) -> Option<SourceDetails> {
    if matches!(snapshot.state, State::Unreachable | State::NoData) {
        return None;
    }
    let on_battery = matches!(snapshot.state, State::OnBattery | State::LowBattery);
    Some(SourceDetails {
        name: name.to_string(),
        charge_percent: snapshot.charge_percent?,
        on_battery,
        charging: !on_battery && snapshot.flags.has("CHRG"),
        minutes_to_empty: snapshot.runtime_seconds.filter(|_| on_battery).map(|seconds| seconds / 60),
    })
}

/// The dictionary handed to macOS, with the keys of Apple's `IOPSKeys.h`.
pub fn dictionary_entries(details: &SourceDetails) -> Vec<(&'static str, Value)> {
    let state = if details.on_battery { "Battery Power" } else { "AC Power" };
    let mut entries = vec![
        ("Name", Value::Text(details.name.clone())),
        ("Type", Value::Text(PS_TYPE.into())),
        ("Transport Type", Value::Text(PS_TRANSPORT.into())),
        ("Accessory Category", Value::Text(PS_CATEGORY.into())),
        ("Power Source State", Value::Text(state.into())),
        ("Is Present", Value::Flag(true)),
        ("Is Charging", Value::Flag(details.charging)),
        ("Current Capacity", Value::Number(i32::from(details.charge_percent))),
        ("Max Capacity", Value::Number(100)),
    ];
    if let Some(minutes) = details.minutes_to_empty.filter(|_| details.on_battery) {
        entries.push(("Time to Empty", Value::Number(i32::try_from(minutes).unwrap_or(i32::MAX))));
    }
    entries
}

pub use platform::Publisher;

#[cfg(target_os = "macos")]
mod platform {
    use std::collections::HashMap;
    use std::ffi::c_void;

    use core_foundation::base::TCFType;
    use core_foundation::boolean::CFBoolean;
    use core_foundation::dictionary::{CFDictionary, CFDictionaryRef};
    use core_foundation::number::CFNumber;
    use core_foundation::string::CFString;

    use super::{dictionary_entries, SourceDetails, Value};

    /// `kIOReturnSuccess`.
    const SUCCESS: i32 = 0;

    #[link(name = "IOKit", kind = "framework")]
    extern "C" {
        fn IOPSCreatePowerSource(out: *mut *mut c_void) -> i32;
        fn IOPSSetPowerSourceDetails(source: *mut c_void, details: CFDictionaryRef) -> i32;
        fn IOPSReleasePowerSource(source: *mut c_void) -> i32;
    }

    /// An opaque `IOPSPowerSourceID`.
    struct SourceId(*mut c_void);

    // The identifier is only a token handed back to IOKit, which serialises its own calls.
    unsafe impl Send for SourceId {}

    /// Owns the sources published by this process; they disappear when it is dropped.
    #[derive(Default)]
    pub struct Publisher {
        sources: HashMap<String, SourceId>,
        disabled: bool,
    }

    impl Publisher {
        pub fn new() -> Publisher {
            Publisher::default()
        }

        /// Publishes or updates the source named `name`; `None` withdraws it.
        /// The first IOKit failure is logged once and turns publishing off for good.
        pub fn set(&mut self, name: &str, details: Option<&SourceDetails>) {
            if self.disabled {
                return;
            }
            let Some(details) = details else {
                if let Some(source) = self.sources.remove(name) {
                    unsafe { IOPSReleasePowerSource(source.0) };
                }
                return;
            };
            if !self.sources.contains_key(name) {
                let mut source: *mut c_void = std::ptr::null_mut();
                let status = unsafe { IOPSCreatePowerSource(&mut source) };
                if status != SUCCESS || source.is_null() {
                    return self.disable("IOPSCreatePowerSource", status);
                }
                self.sources.insert(name.to_string(), SourceId(source));
            }
            let pairs: Vec<_> = dictionary_entries(details)
                .into_iter()
                .map(|(key, value)| {
                    let value = match value {
                        Value::Text(text) => CFString::new(&text).as_CFType(),
                        Value::Flag(flag) => CFBoolean::from(flag).as_CFType(),
                        Value::Number(number) => CFNumber::from(number).as_CFType(),
                    };
                    (CFString::new(key), value)
                })
                .collect();
            let dictionary = CFDictionary::from_CFType_pairs(&pairs);
            let status =
                unsafe { IOPSSetPowerSourceDetails(self.sources[name].0, dictionary.as_concrete_TypeRef()) };
            if status != SUCCESS {
                self.disable("IOPSSetPowerSourceDetails", status);
            }
        }

        pub fn is_disabled(&self) -> bool {
            self.disabled
        }

        fn disable(&mut self, call: &str, status: i32) {
            eprintln!("wattsup: {call} failed ({status:#x}); the Batteries widget is not updated any more");
            self.release_all();
            self.disabled = true;
        }

        fn release_all(&mut self) {
            for (_, source) in self.sources.drain() {
                unsafe { IOPSReleasePowerSource(source.0) };
            }
        }
    }

    impl Drop for Publisher {
        fn drop(&mut self) {
            self.release_all();
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use super::SourceDetails;

    /// There is no Batteries widget outside macOS: publishing does nothing.
    #[derive(Default)]
    pub struct Publisher;

    impl Publisher {
        pub fn new() -> Publisher {
            Publisher
        }

        pub fn set(&mut self, _name: &str, _details: Option<&SourceDetails>) {}

        pub fn is_disabled(&self) -> bool {
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::ClientError;

    fn snapshot(vars: &[(&str, &str)]) -> Snapshot {
        Snapshot::from_vars(vars.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect())
    }

    fn entry<'a>(entries: &'a [(&'static str, Value)], key: &str) -> Option<&'a Value> {
        entries.iter().find(|(name, _)| *name == key).map(|(_, value)| value)
    }

    #[test]
    fn nothing_is_published_without_fresh_data() {
        let unreachable = Snapshot::from_error(&ClientError::Unreachable("no answer".into()));
        let no_data = Snapshot::from_error(&ClientError::NoData("DATA-STALE".into()));
        assert_eq!(details_for("Maison", &unreachable), None);
        assert_eq!(details_for("Maison", &no_data), None);
    }

    #[test]
    fn nothing_is_published_without_a_charge() {
        assert_eq!(details_for("Maison", &snapshot(&[("ups.status", "OL")])), None);
    }

    #[test]
    fn a_full_ups_on_mains_is_neither_charging_nor_on_battery() {
        let details =
            details_for("Maison", &snapshot(&[("ups.status", "OL"), ("battery.charge", "100")])).unwrap();
        assert_eq!(
            details,
            SourceDetails {
                name: "Maison".into(),
                charge_percent: 100,
                on_battery: false,
                charging: false,
                minutes_to_empty: None
            }
        );
    }

    #[test]
    fn a_ups_reporting_chrg_on_mains_is_charging() {
        let details =
            details_for("Maison", &snapshot(&[("ups.status", "OL CHRG"), ("battery.charge", "80")])).unwrap();
        assert!(details.charging);
        assert!(!details.on_battery);
        assert_eq!(details.charge_percent, 80);
    }

    #[test]
    fn a_ups_on_battery_gives_its_runtime_in_minutes() {
        let vars = [("ups.status", "OB DISCHRG"), ("battery.charge", "90"), ("battery.runtime", "2858")];
        let details = details_for("Maison", &snapshot(&vars)).unwrap();
        assert!(details.on_battery);
        assert!(!details.charging);
        assert_eq!(details.minutes_to_empty, Some(47));
    }

    #[test]
    fn a_low_battery_is_on_battery() {
        let details =
            details_for("Maison", &snapshot(&[("ups.status", "OB LB"), ("battery.charge", "8")])).unwrap();
        assert!(details.on_battery);
        assert_eq!(details.minutes_to_empty, None);
    }

    #[test]
    fn the_dictionary_of_a_ups_on_mains() {
        let details = SourceDetails {
            name: "Maison".into(),
            charge_percent: 100,
            on_battery: false,
            charging: false,
            minutes_to_empty: Some(47),
        };
        let entries = dictionary_entries(&details);
        assert_eq!(entry(&entries, "Name"), Some(&Value::Text("Maison".into())));
        assert_eq!(entry(&entries, "Type"), Some(&Value::Text("Accessory Source".into())));
        assert_eq!(entry(&entries, "Transport Type"), Some(&Value::Text("USB".into())));
        assert_eq!(entry(&entries, "Accessory Category"), Some(&Value::Text("Battery Case".into())));
        assert_eq!(entry(&entries, "Power Source State"), Some(&Value::Text("AC Power".into())));
        assert_eq!(entry(&entries, "Is Present"), Some(&Value::Flag(true)));
        assert_eq!(entry(&entries, "Is Charging"), Some(&Value::Flag(false)));
        assert_eq!(entry(&entries, "Current Capacity"), Some(&Value::Number(100)));
        assert_eq!(entry(&entries, "Max Capacity"), Some(&Value::Number(100)));
        assert_eq!(entry(&entries, "Time to Empty"), None);
    }

    #[test]
    fn the_dictionary_of_a_ups_on_battery() {
        let details = SourceDetails {
            name: "Maison".into(),
            charge_percent: 90,
            on_battery: true,
            charging: false,
            minutes_to_empty: Some(47),
        };
        let entries = dictionary_entries(&details);
        assert_eq!(entry(&entries, "Power Source State"), Some(&Value::Text("Battery Power".into())));
        assert_eq!(entry(&entries, "Current Capacity"), Some(&Value::Number(90)));
        assert_eq!(entry(&entries, "Time to Empty"), Some(&Value::Number(47)));
    }

    #[test]
    fn a_ups_on_battery_without_runtime_has_no_time_to_empty() {
        let details = SourceDetails {
            name: "Maison".into(),
            charge_percent: 90,
            on_battery: true,
            charging: false,
            minutes_to_empty: None,
        };
        assert_eq!(entry(&dictionary_entries(&details), "Time to Empty"), None);
    }

    #[test]
    fn no_key_appears_twice() {
        let details = SourceDetails {
            name: "Maison".into(),
            charge_percent: 90,
            on_battery: true,
            charging: false,
            minutes_to_empty: Some(47),
        };
        let mut keys: Vec<&str> = dictionary_entries(&details).iter().map(|(key, _)| *key).collect();
        let count = keys.len();
        keys.sort_unstable();
        keys.dedup();
        assert_eq!(keys.len(), count);
    }
}
