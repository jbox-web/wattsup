//! Turns successive snapshots of one UPS into the events worth a notification.

use crate::model::{Snapshot, State};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
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

/// Consecutive failed polls before a UPS is declared unreachable or without data.
pub const UNREACHABLE_AFTER: u32 = 3;

/// The memory of one UPS between polls.
#[derive(Debug, Clone, Default)]
pub struct Tracker {
    /// The last power state seen: on mains, on battery or low battery.
    power: Option<State>,
    /// `Unreachable`, `NoData` or `Refused`, once declared.
    outage: Option<State>,
    failures: u32,
    replace_battery: bool,
    /// The last poll failed while the Mac itself had no network.
    out_of_reach: bool,
    observed: bool,
}

impl Tracker {
    pub fn new() -> Tracker {
        Tracker::default()
    }

    /// Records a poll and returns what changed. `mac_online` is false when the Mac has no
    /// network path or has just woken up: a failure then says nothing about the site.
    /// The first poll never raises an event.
    pub fn observe(&mut self, snapshot: &Snapshot, mac_online: bool) -> Vec<Event> {
        let failed = matches!(snapshot.state, State::Unreachable | State::NoData | State::Refused);
        if failed && snapshot.state == State::Unreachable && !mac_online {
            self.out_of_reach = true;
            return Vec::new();
        }
        self.out_of_reach = false;
        let first = !self.observed;
        self.observed = true;

        if failed {
            self.failures += 1;
            let declared = self.outage.is_some();
            if first || declared {
                self.outage = Some(snapshot.state);
            } else if self.failures >= UNREACHABLE_AFTER {
                self.outage = Some(snapshot.state);
                let event = match snapshot.state {
                    State::NoData => Event::NoData,
                    State::Refused => Event::Refused,
                    _ => Event::Unreachable,
                };
                return vec![event];
            }
            return Vec::new();
        }

        let mut events = Vec::new();
        self.failures = 0;
        let back = self.outage.take().is_some();
        if back {
            events.push(Event::ReachableAgain);
        }
        let replace_battery = snapshot.flags.has("RB");
        if let Some(previous) = self.power {
            match (previous, snapshot.state) {
                (previous, now) if previous == now => {}
                (_, State::LowBattery) => events.push(Event::LowBattery),
                (State::OnMains, State::OnBattery) => events.push(Event::OnBattery),
                (_, State::OnMains) => events.push(Event::BackOnMains),
                _ => {}
            }
            if replace_battery && !self.replace_battery {
                events.push(Event::ReplaceBattery);
            }
        } else if back {
            // Unreachable since the first poll: the power state was never seen, so a cut in
            // progress is news.
            match snapshot.state {
                State::LowBattery => events.push(Event::LowBattery),
                State::OnBattery => events.push(Event::OnBattery),
                _ => {}
            }
        }
        self.power = Some(snapshot.state);
        self.replace_battery = replace_battery;
        events
    }

    /// The state to show. `None` before the first poll, and while the UPS is out of reach
    /// because the Mac itself is offline.
    pub fn displayed(&self) -> Option<State> {
        if self.out_of_reach {
            None
        } else {
            self.outage.or(self.power)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client::ClientError;

    fn status(status: &str) -> Snapshot {
        Snapshot::from_vars([("ups.status".to_string(), status.to_string())].into())
    }

    fn unreachable() -> Snapshot {
        Snapshot::from_error(&ClientError::Unreachable("no answer within the timeout".into()))
    }

    fn refused() -> Snapshot {
        Snapshot::from_error(&ClientError::Server("ACCESS-DENIED".into()))
    }

    fn no_data() -> Snapshot {
        Snapshot::from_error(&ClientError::NoData("DATA-STALE".into()))
    }

    /// Feeds the snapshots with the Mac online and returns the events of each step.
    fn run(tracker: &mut Tracker, snapshots: &[Snapshot]) -> Vec<Vec<Event>> {
        snapshots.iter().map(|snap| tracker.observe(snap, true)).collect()
    }

    #[test]
    fn the_first_snapshot_raises_nothing() {
        let mut tracker = Tracker::new();
        assert_eq!(tracker.displayed(), None);
        assert_eq!(tracker.observe(&status("OL"), true), vec![]);
        assert_eq!(tracker.displayed(), Some(State::OnMains));
    }

    #[test]
    fn a_first_snapshot_on_battery_or_unreachable_raises_nothing_but_is_displayed() {
        let mut tracker = Tracker::new();
        assert_eq!(tracker.observe(&status("OB"), true), vec![]);
        assert_eq!(tracker.displayed(), Some(State::OnBattery));

        let mut tracker = Tracker::new();
        assert_eq!(tracker.observe(&unreachable(), true), vec![]);
        assert_eq!(tracker.displayed(), Some(State::Unreachable));
    }

    #[test]
    fn follows_a_power_cut_to_its_end() {
        let mut tracker = Tracker::new();
        let events =
            run(&mut tracker, &[status("OL"), status("OB DISCHRG"), status("OB LB"), status("OL CHRG")]);
        assert_eq!(
            events,
            vec![vec![], vec![Event::OnBattery], vec![Event::LowBattery], vec![Event::BackOnMains]]
        );
        assert_eq!(tracker.displayed(), Some(State::OnMains));
    }

    #[test]
    fn a_steady_state_raises_nothing() {
        let mut tracker = Tracker::new();
        let events = run(&mut tracker, &[status("OL"), status("OL"), status("OL CHRG")]);
        assert_eq!(events, vec![vec![], vec![], vec![]]);
    }

    #[test]
    fn declares_unreachable_at_the_third_failure_only() {
        let mut tracker = Tracker::new();
        tracker.observe(&status("OL"), true);
        assert_eq!(tracker.observe(&unreachable(), true), vec![]);
        assert_eq!(tracker.observe(&unreachable(), true), vec![]);
        assert_eq!(tracker.displayed(), Some(State::OnMains));
        assert_eq!(tracker.observe(&unreachable(), true), vec![Event::Unreachable]);
        assert_eq!(tracker.displayed(), Some(State::Unreachable));
        assert_eq!(tracker.observe(&unreachable(), true), vec![]);
        assert_eq!(tracker.observe(&status("OL"), true), vec![Event::ReachableAgain]);
        assert_eq!(tracker.displayed(), Some(State::OnMains));
    }

    #[test]
    fn one_lost_poll_raises_nothing() {
        let mut tracker = Tracker::new();
        let events = run(
            &mut tracker,
            &[status("OL"), unreachable(), status("OL"), unreachable(), unreachable(), status("OL")],
        );
        assert!(events.iter().all(Vec::is_empty), "{events:?}");
    }

    #[test]
    fn failures_while_the_mac_is_offline_do_not_count() {
        let mut tracker = Tracker::new();
        tracker.observe(&status("OL"), true);
        for _ in 0..10 {
            assert_eq!(tracker.observe(&unreachable(), false), vec![]);
            assert_eq!(tracker.displayed(), None);
        }
        assert_eq!(tracker.observe(&unreachable(), true), vec![]);
        assert_eq!(tracker.displayed(), Some(State::OnMains));
        assert_eq!(tracker.observe(&unreachable(), true), vec![]);
        assert_eq!(tracker.observe(&unreachable(), true), vec![Event::Unreachable]);
    }

    #[test]
    fn coming_back_from_offline_without_a_change_raises_nothing() {
        let mut tracker = Tracker::new();
        tracker.observe(&status("OL"), true);
        tracker.observe(&unreachable(), false);
        assert_eq!(tracker.observe(&status("OL"), true), vec![]);
        assert_eq!(tracker.displayed(), Some(State::OnMains));
    }

    #[test]
    fn declares_a_refusal_once_at_the_third_poll() {
        let mut tracker = Tracker::new();
        let events = run(&mut tracker, &[status("OL"), refused(), refused(), refused(), refused()]);
        assert_eq!(events, vec![vec![], vec![], vec![], vec![Event::Refused], vec![]]);
        assert_eq!(tracker.displayed(), Some(State::Refused));
        assert_eq!(tracker.observe(&status("OL"), true), vec![Event::ReachableAgain]);
    }

    #[test]
    fn a_refusal_while_the_mac_is_offline_still_counts() {
        // A refusal is an answer from the server: the Mac's network is not in question.
        let mut tracker = Tracker::new();
        tracker.observe(&status("OL"), true);
        let events: Vec<_> = (0..3).map(|_| tracker.observe(&refused(), false)).collect();
        assert_eq!(events[2], vec![Event::Refused]);
    }

    #[test]
    fn declares_no_data_once() {
        let mut tracker = Tracker::new();
        let events = run(&mut tracker, &[status("OL"), no_data(), no_data(), no_data(), no_data()]);
        assert_eq!(events, vec![vec![], vec![], vec![], vec![Event::NoData], vec![]]);
        assert_eq!(tracker.displayed(), Some(State::NoData));
        assert_eq!(tracker.observe(&status("OL"), true), vec![Event::ReachableAgain]);
    }

    #[test]
    fn notifies_a_battery_to_replace_once_per_appearance() {
        let mut tracker = Tracker::new();
        let events = run(
            &mut tracker,
            &[status("OL"), status("OL RB"), status("OL RB"), status("OL"), status("OL RB")],
        );
        assert_eq!(
            events,
            vec![vec![], vec![Event::ReplaceBattery], vec![], vec![], vec![Event::ReplaceBattery]]
        );
    }

    #[test]
    fn a_battery_to_replace_at_the_first_snapshot_raises_nothing() {
        let mut tracker = Tracker::new();
        let events = run(&mut tracker, &[status("OL RB"), status("OL RB")]);
        assert_eq!(events, vec![vec![], vec![]]);
    }

    #[test]
    fn an_outage_during_a_power_cut_does_not_repeat_on_battery() {
        let mut tracker = Tracker::new();
        let events = run(
            &mut tracker,
            &[status("OL"), status("OB"), unreachable(), unreachable(), unreachable(), status("OB")],
        );
        assert_eq!(events[1], vec![Event::OnBattery]);
        assert_eq!(events[4], vec![Event::Unreachable]);
        assert_eq!(events[5], vec![Event::ReachableAgain]);
    }

    #[test]
    fn a_power_cut_that_started_during_an_outage_is_announced_on_return() {
        let mut tracker = Tracker::new();
        let events =
            run(&mut tracker, &[status("OL"), unreachable(), unreachable(), unreachable(), status("OB")]);
        assert_eq!(events[4], vec![Event::ReachableAgain, Event::OnBattery]);
    }

    #[test]
    fn a_power_cut_seen_right_after_one_lost_poll_is_announced() {
        let mut tracker = Tracker::new();
        let events = run(&mut tracker, &[status("OL"), unreachable(), status("OB")]);
        assert_eq!(events[2], vec![Event::OnBattery]);
    }

    #[test]
    fn a_power_cut_found_after_an_outage_at_launch_is_announced() {
        let mut tracker = Tracker::new();
        let events = run(&mut tracker, &[unreachable(), status("OB")]);
        assert_eq!(events, vec![vec![], vec![Event::ReachableAgain, Event::OnBattery]]);

        let mut tracker = Tracker::new();
        let events = run(&mut tracker, &[unreachable(), status("OB LB")]);
        assert_eq!(events[1], vec![Event::ReachableAgain, Event::LowBattery]);

        let mut tracker = Tracker::new();
        let events = run(&mut tracker, &[unreachable(), status("OL")]);
        assert_eq!(events[1], vec![Event::ReachableAgain]);
    }

    #[test]
    fn low_battery_straight_from_mains_is_announced_as_low_battery() {
        let mut tracker = Tracker::new();
        let events = run(&mut tracker, &[status("OL"), status("OB LB")]);
        assert_eq!(events[1], vec![Event::LowBattery]);
    }
}
