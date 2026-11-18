//! A fake `upsd` to watch the app react: serves one UPS named `ups` whose status follows a
//! timed script.
//! Usage: fake-upsd <port> <status>:<seconds> [<status>:<seconds> ...]
//! Example: fake-upsd 34930 "OL:40" "OB DISCHRG:60" "OL:600"

use std::thread;
use std::time::Duration;

use test_support::FakeUpsd;

fn main() {
    let mut args = std::env::args().skip(1);
    let port: u16 = args.next().and_then(|port| port.parse().ok()).expect("port");
    let server = FakeUpsd::bind(port);
    server.reply("LIST UPS", &["BEGIN LIST UPS", r#"UPS ups "Fake UPS""#, "END LIST UPS"]);
    for step in args {
        let (status, seconds) = step.rsplit_once(':').expect("<status>:<seconds>");
        let on_battery = status.contains("OB");
        server.vars(
            "ups",
            &[
                ("ups.status", status),
                ("battery.charge", if on_battery { "87" } else { "100" }),
                ("battery.runtime", "2858"),
                ("ups.load", "10"),
                ("device.model", "Fake UPS"),
            ],
        );
        println!("status: {status} for {seconds}s");
        thread::sleep(Duration::from_secs(seconds.parse().expect("seconds")));
    }
}
