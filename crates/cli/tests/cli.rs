use std::fs;
use std::net::TcpListener;
use std::path::PathBuf;
use std::process::{Command, Output};

use test_support::FakeUpsd;

const VARS: &[(&str, &str)] = &[
    ("ups.status", "OL"),
    ("battery.charge", "100"),
    ("battery.runtime", "2858"),
    ("ups.load", "10"),
    ("device.model", "Back-UPS BX950MI "),
];

struct Setup {
    _dir: tempfile::TempDir,
    config: PathBuf,
}

/// Writes a configuration with one entry per (name, port).
fn setup(entries: &[(&str, u16)]) -> Setup {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("config.toml");
    let text: String = entries
        .iter()
        .map(|(name, port)| {
            format!("[[ups]]\nname = \"{name}\"\nhost = \"127.0.0.1\"\nport = {port}\nups = \"ups\"\n\n")
        })
        .collect();
    fs::write(&config, text).unwrap();
    Setup { _dir: dir, config }
}

fn closed_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn run(setup: &Setup, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_wattsup"))
        .arg("--config")
        .arg(&setup.config)
        .args(args)
        .output()
        .unwrap()
}

fn stdout(output: &Output) -> String {
    String::from_utf8(output.stdout.clone()).unwrap()
}

fn stderr(output: &Output) -> String {
    String::from_utf8(output.stderr.clone()).unwrap()
}

/// The words of each line, so that column alignment does not matter.
fn rows(text: &str) -> Vec<String> {
    text.lines().map(|line| line.split_whitespace().collect::<Vec<_>>().join(" ")).collect()
}

#[test]
fn status_prints_one_line_per_ups() {
    let server = FakeUpsd::start();
    server.vars("ups", VARS);
    let setup = setup(&[("Maison", server.port())]);

    let output = run(&setup, &["status"]);

    assert_eq!(rows(&stdout(&output)), ["NAME STATE CHARGE RUNTIME LOAD", "Maison on mains 100% 47m 10%"]);
    assert_eq!(output.status.code(), Some(0));
}

#[test]
fn status_shows_an_unreachable_ups_without_hiding_the_other() {
    let server = FakeUpsd::start();
    server.vars("ups", VARS);
    let setup = setup(&[("Maison", server.port()), ("Bureau", closed_port())]);

    let output = run(&setup, &["status"]);

    assert_eq!(
        rows(&stdout(&output)),
        ["NAME STATE CHARGE RUNTIME LOAD", "Maison on mains 100% 47m 10%", "Bureau unreachable - - -"]
    );
    assert_eq!(output.status.code(), Some(1));
}

#[test]
fn status_shows_missing_values_as_dashes() {
    let server = FakeUpsd::start();
    server.vars("ups", &[("ups.status", "OB DISCHRG"), ("battery.charge", "42")]);
    let setup = setup(&[("Maison", server.port())]);

    let output = run(&setup, &["status"]);

    assert_eq!(rows(&stdout(&output))[1], "Maison on battery 42% - -");
    assert_eq!(output.status.code(), Some(0));
}

#[test]
fn status_formats_a_long_runtime_in_hours() {
    let server = FakeUpsd::start();
    server.vars("ups", &[("ups.status", "OL"), ("battery.runtime", "3900")]);
    let setup = setup(&[("Maison", server.port())]);

    let output = run(&setup, &["status"]);

    assert_eq!(rows(&stdout(&output))[1], "Maison on mains - 1h05m -");
}

#[test]
fn status_reports_a_refusal_of_the_server_as_refused() {
    let server = FakeUpsd::start();
    server.reply("LIST VAR ups", &["ERR ACCESS-DENIED"]);
    let setup = setup(&[("Maison", server.port())]);

    let output = run(&setup, &["status"]);
    assert_eq!(rows(&stdout(&output))[1], "Maison refused - - -");
    assert_eq!(output.status.code(), Some(1));

    let output = run(&setup, &["--json", "status"]);
    let json: serde_json::Value = serde_json::from_str(&stdout(&output)).unwrap();
    assert_eq!(json[0]["state"], "refused");
    assert!(json[0]["error"].as_str().unwrap().contains("ACCESS-DENIED"));
}

#[test]
fn status_reports_stale_data_as_no_data() {
    let server = FakeUpsd::start();
    server.reply("LIST VAR ups", &["ERR DATA-STALE"]);
    let setup = setup(&[("Maison", server.port())]);

    let output = run(&setup, &["status"]);

    assert_eq!(rows(&stdout(&output))[1], "Maison no data - - -");
    assert_eq!(output.status.code(), Some(1));
}

#[test]
fn status_without_any_ups_says_so() {
    let setup = setup(&[]);

    let output = run(&setup, &["status"]);

    assert_eq!(stdout(&output), "");
    assert!(stderr(&output).contains("no UPS configured"), "{}", stderr(&output));
    assert_eq!(output.status.code(), Some(0));
}

#[test]
fn vars_prints_every_variable_sorted() {
    let server = FakeUpsd::start();
    server.vars("ups", VARS);
    let setup = setup(&[("Maison", server.port())]);

    let output = run(&setup, &["vars", "Maison"]);

    assert_eq!(
        stdout(&output),
        "battery.charge: 100\nbattery.runtime: 2858\ndevice.model: Back-UPS BX950MI \nups.load: 10\nups.status: OL\n"
    );
    assert_eq!(output.status.code(), Some(0));
}

#[test]
fn vars_finds_the_ups_whatever_the_case() {
    let server = FakeUpsd::start();
    server.vars("ups", VARS);
    let setup = setup(&[("Maison", server.port())]);

    let output = run(&setup, &["vars", "maison"]);

    assert!(stdout(&output).contains("ups.status: OL\n"), "{}", stdout(&output));
    assert_eq!(output.status.code(), Some(0));
}

#[test]
fn vars_of_an_unknown_ups_is_a_usage_error() {
    let setup = setup(&[("Maison", closed_port())]);

    let output = run(&setup, &["vars", "Inconnu"]);

    assert!(stderr(&output).contains("no UPS named \"Inconnu\""), "{}", stderr(&output));
    assert_eq!(output.status.code(), Some(2));
}

#[test]
fn vars_of_an_unreachable_ups_fails() {
    let setup = setup(&[("Maison", closed_port())]);

    let output = run(&setup, &["vars", "Maison"]);

    assert!(stderr(&output).contains("unreachable"), "{}", stderr(&output));
    assert_eq!(output.status.code(), Some(1));
}

#[test]
fn list_prints_the_names_a_server_offers() {
    let server = FakeUpsd::start();
    server.reply("LIST UPS", &["BEGIN LIST UPS", r#"UPS ups "Garage""#, "END LIST UPS"]);
    let setup = setup(&[]);

    let output = run(&setup, &["list", &format!("127.0.0.1:{}", server.port())]);

    assert_eq!(rows(&stdout(&output)), ["ups Garage"]);
    assert_eq!(output.status.code(), Some(0));
}

#[test]
fn status_as_json() {
    let server = FakeUpsd::start();
    server.vars("ups", VARS);
    let setup = setup(&[("Maison", server.port()), ("Bureau", closed_port())]);

    let output = run(&setup, &["--json", "status"]);

    let json: serde_json::Value = serde_json::from_str(&stdout(&output)).unwrap();
    assert_eq!(json[0]["name"], "Maison");
    assert_eq!(json[0]["state"], "on_mains");
    assert_eq!(json[0]["charge_percent"], 100);
    assert_eq!(json[0]["runtime_seconds"], 2858);
    assert_eq!(json[0]["load_percent"], 10);
    assert_eq!(json[0]["load_watts"], serde_json::Value::Null);
    assert_eq!(json[0]["model"], "Back-UPS BX950MI");
    assert_eq!(json[0]["flags"], serde_json::json!(["OL"]));
    assert_eq!(json[0]["vars"]["ups.status"], "OL");
    assert_eq!(json[1]["state"], "unreachable");
    assert_eq!(json[1]["charge_percent"], serde_json::Value::Null);
    assert!(json[1]["error"].as_str().unwrap().contains("unreachable"));
    assert_eq!(output.status.code(), Some(1));
}

#[test]
fn vars_as_json_is_an_object() {
    let server = FakeUpsd::start();
    server.vars("ups", VARS);
    let setup = setup(&[("Maison", server.port())]);

    let output = run(&setup, &["--json", "vars", "Maison"]);

    let json: serde_json::Value = serde_json::from_str(&stdout(&output)).unwrap();
    assert_eq!(json["battery.charge"], "100");
}

#[test]
fn an_invalid_configuration_is_reported_with_its_path() {
    let setup = setup(&[]);
    fs::write(&setup.config, "[[ups]\n").unwrap();

    let output = run(&setup, &["status"]);

    assert!(stderr(&output).contains(setup.config.to_str().unwrap()), "{}", stderr(&output));
    assert_eq!(output.status.code(), Some(2));
}

#[test]
fn a_password_missing_from_the_keychain_does_not_hide_the_other_upses() {
    let server = FakeUpsd::start();
    server.vars("ups", VARS);
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("config.toml");
    // A name no Keychain holds a password for.
    let name = format!("NoPassword{}", std::process::id());
    fs::write(
        &config,
        format!(
            "[[ups]]\nname = \"Maison\"\nhost = \"127.0.0.1\"\nport = {port}\nups = \"ups\"\n\n\
             [[ups]]\nname = \"{name}\"\nhost = \"127.0.0.1\"\nport = {port}\nups = \"ups\"\nusername = \"monuser\"\n",
            port = server.port()
        ),
    )
    .unwrap();
    let setup = Setup { _dir: dir, config };

    let output = run(&setup, &["status"]);

    let rows = rows(&stdout(&output));
    assert_eq!(rows.len(), 3, "{rows:?}");
    assert_eq!(rows[1], "Maison on mains 100% 47m 10%");
    assert!(rows[2].starts_with(&name), "{rows:?}");
    assert!(
        stderr(&output).contains(&format!("no password for \"{name}\" in the Keychain")),
        "{}",
        stderr(&output)
    );
}

#[test]
fn list_reads_an_ipv6_address() {
    let server = FakeUpsd::start();
    server.reply("LIST UPS", &["BEGIN LIST UPS", r#"UPS ups "Garage""#, "END LIST UPS"]);
    let setup = setup(&[]);

    // Nothing listens on these: what matters is the address the client tried, which the
    // error names (host ::1, then the port given or the default 3493).
    let output = run(&setup, &["list", "[::1]:1"]);
    assert!(stderr(&output).contains("[::1]:1: "), "{}", stderr(&output));
    let output = run(&setup, &["list", "::1"]);
    assert!(stderr(&output).contains("[::1]:3493: "), "{}", stderr(&output));

    let output = run(&setup, &["list", &format!("127.0.0.1:{}", server.port())]);
    assert_eq!(rows(&stdout(&output)), ["ups Garage"]);
}
