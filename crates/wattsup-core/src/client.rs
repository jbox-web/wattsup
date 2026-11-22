//! Blocking, read-only NUT client: one short connection per request.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
use std::net::{SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use thiserror::Error;

use crate::protocol::{first_word, parse_line, Line, ProtocolError};

/// Default connect, read and write timeout.
pub const TIMEOUT: Duration = Duration::from_secs(5);
/// A whole request (resolution, connection, every line of the answer) gets this many
/// timeouts: a server that keeps sending a little at a time is cut off all the same.
const DEADLINE_TIMEOUTS: u32 = 3;
/// The longest reply line accepted; a NUT line is a few hundred bytes at most.
pub const MAX_LINE: usize = 64 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub host: String,
    pub port: u16,
}

#[derive(Clone, PartialEq, Eq)]
pub struct Credentials {
    pub username: String,
    pub password: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ClientError {
    /// No usable answer: refused, timed out, unresolved, or cut mid-reply.
    #[error("unreachable: {0}")]
    Unreachable(String),
    /// The server answers but has nothing fresh from the UPS; holds the NUT error code.
    #[error("the server has no data from the UPS ({0})")]
    NoData(String),
    /// Any other NUT error; holds the error code only, never the server's extra words.
    #[error("the server refused the request ({0})")]
    Server(String),
    #[error(transparent)]
    Protocol(#[from] ProtocolError),
}

/// The UPS names a server offers, with their descriptions.
pub fn list_ups(endpoint: &Endpoint, timeout: Duration) -> Result<Vec<(String, String)>, ClientError> {
    let mut connection = Connection::open(endpoint, timeout)?;
    connection.send("LIST UPS")?;
    let mut names = Vec::new();
    loop {
        match connection.read()? {
            Line::Ups { name, description } => names.push((name, description)),
            Line::EndList => break,
            Line::BeginList => {}
            other => return Err(unexpected(other)),
        }
    }
    connection.logout();
    Ok(names)
}

/// Every variable of one UPS.
pub fn list_vars(
    endpoint: &Endpoint,
    ups: &str,
    credentials: Option<&Credentials>,
    timeout: Duration,
) -> Result<BTreeMap<String, String>, ClientError> {
    // Checked before connecting: a line break would smuggle a second command in.
    let mut arguments = vec![ups];
    if let Some(credentials) = credentials {
        arguments.extend([credentials.username.as_str(), credentials.password.as_str()]);
    }
    if arguments.iter().any(|argument| argument.chars().any(char::is_control)) {
        return Err(ProtocolError::InvalidArgument.into());
    }
    let mut connection = Connection::open(endpoint, timeout)?;
    if let Some(credentials) = credentials {
        connection.expect_ok(&format!("USERNAME {}", element(&credentials.username)))?;
        connection.expect_ok(&format!("PASSWORD {}", element(&credentials.password)))?;
    }
    connection.send(&format!("LIST VAR {}", element(ups)))?;
    let mut vars = BTreeMap::new();
    loop {
        match connection.read()? {
            Line::Var { name, value, .. } => {
                vars.insert(name, value);
            }
            Line::EndList => break,
            Line::BeginList => {}
            other => return Err(unexpected(other)),
        }
    }
    connection.logout();
    Ok(vars)
}

/// Writes one protocol element: quoted and escaped when it is not a plain word.
fn element(text: &str) -> String {
    let plain = !text.is_empty() && !text.contains([' ', '"', '\\']);
    if plain {
        text.to_string()
    } else {
        format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\""))
    }
}

/// Names the kind of line only: its content could be anything, a secret included.
fn unexpected(line: Line) -> ClientError {
    let kind = match line {
        Line::Var { .. } => "VAR",
        Line::Ups { .. } => "UPS",
        Line::BeginList => "BEGIN",
        Line::EndList => "END",
        Line::Ok => "OK",
        Line::Err(_) => "ERR",
    };
    ClientError::Protocol(ProtocolError::Unexpected(kind.to_string()))
}

/// Resolves a host name, waiting at most `timeout`: the system resolver has no timeout of
/// its own. A resolution that takes longer finishes in the background and is ignored.
fn resolve(endpoint: &Endpoint, timeout: Duration) -> Result<Vec<SocketAddr>, ClientError> {
    // An address needs no lookup, and no thread.
    if let Ok(ip) = endpoint.host.parse::<std::net::IpAddr>() {
        return Ok(vec![SocketAddr::new(ip, endpoint.port)]);
    }
    let (host, port) = (endpoint.host.clone(), endpoint.port);
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || {
        let _ = sender.send((host.as_str(), port).to_socket_addrs().map(Iterator::collect::<Vec<_>>));
    });
    match receiver.recv_timeout(timeout) {
        Ok(Ok(addresses)) => Ok(addresses),
        Ok(Err(e)) => Err(ClientError::Unreachable(format!("cannot resolve {}: {e}", endpoint.host))),
        Err(_) => Err(ClientError::Unreachable(format!(
            "cannot resolve {}: no answer within the timeout",
            endpoint.host
        ))),
    }
}

struct Connection {
    reader: BufReader<Deadlined>,
    writer: TcpStream,
}

/// A socket whose every read is held to the request's deadline: a server that sends a byte
/// now and then, without ever ending its line, is cut off all the same.
struct Deadlined {
    stream: TcpStream,
    timeout: Duration,
    deadline: Instant,
}

impl Read for Deadlined {
    fn read(&mut self, buffer: &mut [u8]) -> std::io::Result<usize> {
        let remaining = self.deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(std::io::Error::new(
                ErrorKind::TimedOut,
                "no complete answer within the time allowed",
            ));
        }
        self.stream.set_read_timeout(Some(self.timeout.min(remaining)))?;
        self.stream.read(buffer)
    }
}

impl Connection {
    fn open(endpoint: &Endpoint, timeout: Duration) -> Result<Connection, ClientError> {
        let deadline = Instant::now() + timeout * DEADLINE_TIMEOUTS;
        let addresses = resolve(endpoint, timeout)?;
        let mut last_error = format!("{} has no address", endpoint.host);
        for address in addresses {
            // Each attempt within what is left of the request's time, not a full timeout each.
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            let attempt = TcpStream::connect_timeout(&address, timeout.min(remaining)).and_then(|stream| {
                // On some macOS versions a refused connection yields a dead socket; this unmasks it.
                stream.peer_addr()?;
                stream.set_read_timeout(Some(timeout))?;
                stream.set_write_timeout(Some(timeout))?;
                let writer = stream.try_clone()?;
                Ok(Connection { reader: BufReader::new(Deadlined { stream, timeout, deadline }), writer })
            });
            match attempt {
                Ok(connection) => return Ok(connection),
                Err(e) => last_error = format!("{address}: {e}"),
            }
        }
        Err(ClientError::Unreachable(last_error))
    }

    fn send(&mut self, command: &str) -> Result<(), ClientError> {
        writeln!(self.writer, "{command}").map_err(|e| ClientError::Unreachable(describe(&e)))
    }

    /// Reads one line; a NUT error reply becomes the matching `ClientError`.
    fn read(&mut self) -> Result<Line, ClientError> {
        let read_error = |e: std::io::Error| ClientError::Unreachable(describe(&e));
        // Bytes, not `read_line`: a value in another encoding than UTF-8 must not fail the poll.
        // At most MAX_LINE of them: a line without end must not fill the memory.
        let mut bytes = Vec::new();
        let read =
            (&mut self.reader).take(MAX_LINE as u64).read_until(b'\n', &mut bytes).map_err(read_error)?;
        if read == 0 {
            return Err(ClientError::Unreachable("connection closed by the server".into()));
        }
        if bytes.last() != Some(&b'\n') && read == MAX_LINE {
            return Err(ProtocolError::LineTooLong(MAX_LINE).into());
        }
        let line = String::from_utf8_lossy(&bytes);
        match parse_line(line.trim_end_matches('\n'))? {
            Line::Err(code) if code == "DATA-STALE" || code == "DRIVER-NOT-CONNECTED" => {
                Err(ClientError::NoData(code))
            }
            // The code is one word, but a server can send anything: at most 32 characters.
            Line::Err(code) => Err(ClientError::Server(first_word(&code))),
            line => Ok(line),
        }
    }

    fn expect_ok(&mut self, command: &str) -> Result<(), ClientError> {
        self.send(command)?;
        match self.read()? {
            Line::Ok => Ok(()),
            other => Err(unexpected(other)),
        }
    }

    /// Best effort: the reply does not matter.
    fn logout(&mut self) {
        let _ = self.send("LOGOUT");
    }
}

fn describe(error: &std::io::Error) -> String {
    match error.kind() {
        ErrorKind::WouldBlock | ErrorKind::TimedOut => "no answer within the timeout".into(),
        _ => error.to_string(),
    }
}
