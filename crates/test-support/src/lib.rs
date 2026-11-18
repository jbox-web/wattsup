//! A fake `upsd` for tests: answers scripted replies on a local port.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};
use std::thread;

#[derive(Default)]
struct State {
    replies: HashMap<String, Vec<String>>,
    received: Vec<String>,
    silent: bool,
}

/// Listens on `127.0.0.1` on a free port until dropped by the process exit.
pub struct FakeUpsd {
    port: u16,
    state: Arc<Mutex<State>>,
}

impl FakeUpsd {
    /// Starts a server that answers `ERR UNKNOWN-COMMAND` to everything.
    pub fn start() -> FakeUpsd {
        FakeUpsd::bind(0)
    }

    /// Starts on a given port (0 = any free port).
    pub fn bind(port: u16) -> FakeUpsd {
        let listener = TcpListener::bind(("127.0.0.1", port)).expect("bind");
        let port = listener.local_addr().expect("local addr").port();
        let state = Arc::new(Mutex::new(State::default()));
        let shared = Arc::clone(&state);
        thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let shared = Arc::clone(&shared);
                thread::spawn(move || serve(stream, shared));
            }
        });
        FakeUpsd { port, state }
    }

    /// Starts a server that accepts connections and never answers.
    pub fn silent() -> FakeUpsd {
        let server = FakeUpsd::start();
        server.state.lock().unwrap().silent = true;
        server
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// Sets the lines sent back when `command` is received, replacing any earlier reply.
    pub fn reply(&self, command: &str, lines: &[&str]) -> &FakeUpsd {
        let lines = lines.iter().map(|l| l.to_string()).collect();
        self.state.lock().unwrap().replies.insert(command.to_string(), lines);
        self
    }

    /// Scripts `LIST VAR <ups>` from name/value pairs.
    pub fn vars(&self, ups: &str, vars: &[(&str, &str)]) -> &FakeUpsd {
        let mut lines = vec![format!("BEGIN LIST VAR {ups}")];
        lines.extend(vars.iter().map(|(name, value)| format!("VAR {ups} {name} \"{value}\"")));
        lines.push(format!("END LIST VAR {ups}"));
        let lines: Vec<&str> = lines.iter().map(String::as_str).collect();
        self.reply(&format!("LIST VAR {ups}"), &lines)
    }

    /// Every command received so far, in order, over all connections.
    pub fn received(&self) -> Vec<String> {
        self.state.lock().unwrap().received.clone()
    }
}

fn serve(stream: TcpStream, state: Arc<Mutex<State>>) {
    let mut writer = match stream.try_clone() {
        Ok(writer) => writer,
        Err(_) => return,
    };
    for line in BufReader::new(stream).lines() {
        let Ok(command) = line else { return };
        let lines = {
            let mut state = state.lock().unwrap();
            state.received.push(command.clone());
            if state.silent {
                continue;
            }
            state.replies.get(&command).cloned().unwrap_or_else(|| vec!["ERR UNKNOWN-COMMAND".to_string()])
        };
        for line in lines {
            if writeln!(writer, "{line}").is_err() {
                return;
            }
        }
    }
}
