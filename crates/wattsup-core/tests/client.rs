use std::collections::BTreeMap;
use std::net::TcpListener;
use std::time::{Duration, Instant};

use test_support::FakeUpsd;
use wattsup_core::client::{list_ups, list_vars, ClientError, Credentials, Endpoint};

const TIMEOUT: Duration = Duration::from_secs(2);

fn endpoint(server: &FakeUpsd) -> Endpoint {
    Endpoint { host: "127.0.0.1".into(), port: server.port() }
}

fn credentials() -> Credentials {
    Credentials { username: "monuser".into(), password: "secret".into() }
}

#[test]
fn lists_variables() {
    let server = FakeUpsd::start();
    server.vars("ups", &[("battery.charge", "100"), ("ups.status", "OL")]);

    let vars = list_vars(&endpoint(&server), "ups", None, TIMEOUT).unwrap();

    let expected: BTreeMap<String, String> =
        [("battery.charge", "100"), ("ups.status", "OL")].map(|(k, v)| (k.to_string(), v.to_string())).into();
    assert_eq!(vars, expected);
}

#[test]
fn lists_ups_names() {
    let server = FakeUpsd::start();
    server.reply(
        "LIST UPS",
        &["BEGIN LIST UPS", r#"UPS ups "Garage""#, r#"UPS ups2 "Bureau""#, "END LIST UPS"],
    );

    let names = list_ups(&endpoint(&server), TIMEOUT).unwrap();

    assert_eq!(
        names,
        vec![("ups".to_string(), "Garage".to_string()), ("ups2".to_string(), "Bureau".to_string())]
    );
}

#[test]
fn sends_credentials_before_listing() {
    let server = FakeUpsd::start();
    server
        .reply("USERNAME monuser", &["OK"])
        .reply("PASSWORD secret", &["OK"])
        .vars("ups", &[("ups.status", "OL")]);

    list_vars(&endpoint(&server), "ups", Some(&credentials()), TIMEOUT).unwrap();

    assert_eq!(server.received()[..3], ["USERNAME monuser", "PASSWORD secret", "LIST VAR ups"]);
}

#[test]
fn sends_no_credentials_when_none_are_given() {
    let server = FakeUpsd::start();
    server.vars("ups", &[("ups.status", "OL")]);

    list_vars(&endpoint(&server), "ups", None, TIMEOUT).unwrap();

    assert_eq!(server.received()[0], "LIST VAR ups");
}

#[test]
fn maps_stale_data_to_no_data() {
    let server = FakeUpsd::start();
    server.reply("LIST VAR ups", &["ERR DATA-STALE"]);

    let error = list_vars(&endpoint(&server), "ups", None, TIMEOUT).unwrap_err();

    assert!(matches!(error, ClientError::NoData(ref code) if code == "DATA-STALE"), "{error:?}");
}

#[test]
fn maps_a_disconnected_driver_to_no_data() {
    let server = FakeUpsd::start();
    server.reply("LIST VAR ups", &["ERR DRIVER-NOT-CONNECTED"]);

    let error = list_vars(&endpoint(&server), "ups", None, TIMEOUT).unwrap_err();

    assert!(matches!(error, ClientError::NoData(ref code) if code == "DRIVER-NOT-CONNECTED"), "{error:?}");
}

#[test]
fn maps_unknown_ups_to_server_error() {
    let server = FakeUpsd::start();
    server.reply("LIST VAR nope", &["ERR UNKNOWN-UPS"]);

    let error = list_vars(&endpoint(&server), "nope", None, TIMEOUT).unwrap_err();

    assert!(matches!(error, ClientError::Server(ref code) if code == "UNKNOWN-UPS"), "{error:?}");
}

#[test]
fn maps_access_denied_to_server_error() {
    let server = FakeUpsd::start();
    server.reply("USERNAME monuser", &["OK"]).reply("PASSWORD secret", &["ERR ACCESS-DENIED"]);

    let error = list_vars(&endpoint(&server), "ups", Some(&credentials()), TIMEOUT).unwrap_err();

    assert!(matches!(error, ClientError::Server(ref code) if code == "ACCESS-DENIED"), "{error:?}");
}

#[test]
fn error_never_contains_password() {
    let server = FakeUpsd::start();
    server.reply("USERNAME monuser", &["OK"]).reply("PASSWORD secret", &["ERR ACCESS-DENIED secret"]);

    let error = list_vars(&endpoint(&server), "ups", Some(&credentials()), TIMEOUT).unwrap_err();

    assert!(!error.to_string().contains("secret"), "{error}");
    assert!(!format!("{error:?}").contains("secret"), "{error:?}");
}

#[test]
fn times_out_on_silent_server() {
    let server = FakeUpsd::silent();
    let started = Instant::now();

    let error = list_vars(&endpoint(&server), "ups", None, Duration::from_millis(300)).unwrap_err();

    assert!(matches!(error, ClientError::Unreachable(_)), "{error:?}");
    assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
}

#[test]
fn refused_connection_is_unreachable() {
    let port = {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.local_addr().unwrap().port()
    };

    let error = list_vars(&Endpoint { host: "127.0.0.1".into(), port }, "ups", None, TIMEOUT).unwrap_err();

    assert!(matches!(error, ClientError::Unreachable(_)), "{error:?}");
}

#[test]
fn an_unfinished_list_is_unreachable() {
    let server = FakeUpsd::start();
    server.reply("LIST VAR ups", &["BEGIN LIST VAR ups", r#"VAR ups ups.status "OL""#]);

    let error = list_vars(&endpoint(&server), "ups", None, Duration::from_millis(300)).unwrap_err();

    assert!(matches!(error, ClientError::Unreachable(_)), "{error:?}");
}

#[test]
fn an_unparsable_reply_is_a_protocol_error() {
    let server = FakeUpsd::start();
    server.reply("LIST VAR ups", &["BEGIN LIST VAR ups", "NONSENSE", "END LIST VAR ups"]);

    let error = list_vars(&endpoint(&server), "ups", None, TIMEOUT).unwrap_err();

    assert!(matches!(error, ClientError::Protocol(_)), "{error:?}");
}

#[test]
fn quotes_a_password_containing_spaces_and_quotes() {
    let server = FakeUpsd::start();
    server.reply("USERNAME monuser", &["OK"]).reply(r#"PASSWORD "a b\"c\\d""#, &["OK"]).vars("ups", &[]);
    let credentials = Credentials { username: "monuser".into(), password: r#"a b"c\d"#.into() };

    list_vars(&endpoint(&server), "ups", Some(&credentials), TIMEOUT).unwrap();

    assert_eq!(server.received()[1], r#"PASSWORD "a b\"c\\d""#);
}

#[test]
fn a_value_that_is_not_utf8_does_not_lose_the_ups() {
    use std::io::{BufRead, BufReader, Write};
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut writer = stream.try_clone().unwrap();
        let mut command = String::new();
        BufReader::new(stream).read_line(&mut command).unwrap();
        // "Caf\xE9" is Latin-1, not UTF-8.
        writer.write_all(b"BEGIN LIST VAR ups\nVAR ups device.model \"Caf\xE9\"\nVAR ups ups.status \"OL\"\nEND LIST VAR ups\n").unwrap();
    });

    let vars = list_vars(&Endpoint { host: "127.0.0.1".into(), port }, "ups", None, TIMEOUT).unwrap();

    assert_eq!(vars.get("ups.status").map(String::as_str), Some("OL"));
    assert_eq!(vars.get("device.model").map(String::as_str), Some("Caf\u{FFFD}"));
}

/// A server on a local port that runs `script` for the first connection.
fn scripted<F>(script: F) -> Endpoint
where
    F: FnOnce(std::net::TcpStream) + Send + 'static,
{
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        if let Ok((stream, _)) = listener.accept() {
            script(stream);
        }
    });
    Endpoint { host: "127.0.0.1".into(), port }
}

#[test]
fn a_server_that_keeps_talking_is_cut_off_by_the_overall_deadline() {
    use std::io::Write;
    let endpoint = scripted(|mut stream| {
        stream.write_all(b"BEGIN LIST VAR ups\n").unwrap();
        // One line every 100 ms, for ever: each read succeeds, the answer never ends.
        for i in 0.. {
            std::thread::sleep(Duration::from_millis(100));
            if writeln!(stream, "VAR ups x{i} \"1\"").is_err() {
                return;
            }
        }
    });
    let started = Instant::now();

    let error = list_vars(&endpoint, "ups", None, Duration::from_millis(300)).unwrap_err();

    assert!(matches!(error, ClientError::Unreachable(_)), "{error:?}");
    assert!(started.elapsed() < Duration::from_secs(3), "{:?}", started.elapsed());
}

#[test]
fn an_endless_line_is_refused() {
    use std::io::Write;
    let endpoint = scripted(|mut stream| {
        let chunk = [b'a'; 4096];
        // 1 MiB without a line break, then silence.
        for _ in 0..256 {
            if stream.write_all(&chunk).is_err() {
                return;
            }
        }
        std::thread::sleep(Duration::from_secs(5));
    });

    let error = list_vars(&endpoint, "ups", None, TIMEOUT).unwrap_err();

    assert!(matches!(error, ClientError::Protocol(_)), "{error:?}");
}

#[test]
fn an_unexpected_reply_does_not_echo_the_server_line() {
    let server = FakeUpsd::start();
    server.reply("USERNAME monuser", &["OK"]).reply("PASSWORD secret", &[r#"VAR ups leak "hunter2""#]);

    let error = list_vars(&endpoint(&server), "ups", Some(&credentials()), TIMEOUT).unwrap_err();

    assert!(matches!(error, ClientError::Protocol(_)), "{error:?}");
    assert!(!error.to_string().contains("hunter2"), "{error}");
}

#[test]
fn a_garbage_line_is_reported_by_its_first_word_only() {
    let server = FakeUpsd::start();
    server.reply("LIST VAR ups", &["BEGIN LIST VAR ups", "NONSENSE with hunter2 inside", "END LIST VAR ups"]);

    let error = list_vars(&endpoint(&server), "ups", None, TIMEOUT).unwrap_err();

    assert!(error.to_string().contains("NONSENSE"), "{error}");
    assert!(!error.to_string().contains("hunter2"), "{error}");
}

#[test]
fn a_line_break_in_an_argument_is_refused_before_anything_is_sent() {
    let server = FakeUpsd::start();
    server.vars("ups", &[("ups.status", "OL")]);
    let sneaky = Credentials { username: "monuser\nLIST UPS".into(), password: "secret".into() };

    let error = list_vars(&endpoint(&server), "ups", Some(&sneaky), TIMEOUT).unwrap_err();
    assert!(matches!(error, ClientError::Protocol(_)), "{error:?}");
    let error = list_vars(&endpoint(&server), "ups\rLIST UPS", None, TIMEOUT).unwrap_err();
    assert!(matches!(error, ClientError::Protocol(_)), "{error:?}");

    std::thread::sleep(Duration::from_millis(100));
    assert!(server.received().is_empty(), "{:?}", server.received());
}

#[test]
fn a_server_that_drips_bytes_without_a_line_break_is_cut_off_by_the_overall_deadline() {
    use std::io::Write;
    let endpoint = scripted(|mut stream| {
        // One byte every 100 ms, never a line break: each socket read succeeds.
        loop {
            std::thread::sleep(Duration::from_millis(100));
            if stream.write_all(b"a").is_err() {
                return;
            }
        }
    });
    let started = Instant::now();

    let error = list_vars(&endpoint, "ups", None, Duration::from_millis(300)).unwrap_err();

    assert!(matches!(error, ClientError::Unreachable(_)), "{error:?}");
    assert!(started.elapsed() < Duration::from_secs(3), "{:?}", started.elapsed());
}

#[test]
fn a_long_error_code_is_cut_short() {
    let long = "X".repeat(1000);
    let server = FakeUpsd::start();
    server.reply("LIST VAR ups", &[&format!("ERR {long}")]);

    let error = list_vars(&endpoint(&server), "ups", None, TIMEOUT).unwrap_err();

    assert!(error.to_string().len() < 100, "{} bytes", error.to_string().len());
}
