//! Blocking, read-only NUT client: one short connection per request.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::net::{TcpStream, ToSocketAddrs};
use std::time::Duration;

use thiserror::Error;

use crate::protocol::{parse_line, Line, ProtocolError};

/// Default connect, read and write timeout.
pub const TIMEOUT: Duration = Duration::from_secs(5);

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

fn unexpected(line: Line) -> ClientError {
    ClientError::Protocol(ProtocolError::Unexpected(format!("{line:?}")))
}

struct Connection {
    reader: BufReader<TcpStream>,
    writer: TcpStream,
}

impl Connection {
    fn open(endpoint: &Endpoint, timeout: Duration) -> Result<Connection, ClientError> {
        let addresses = (endpoint.host.as_str(), endpoint.port)
            .to_socket_addrs()
            .map_err(|e| ClientError::Unreachable(format!("cannot resolve {}: {e}", endpoint.host)))?;
        let mut last_error = format!("{} has no address", endpoint.host);
        for address in addresses {
            let attempt = TcpStream::connect_timeout(&address, timeout).and_then(|stream| {
                // On some macOS versions a refused connection yields a dead socket; this unmasks it.
                stream.peer_addr()?;
                stream.set_read_timeout(Some(timeout))?;
                stream.set_write_timeout(Some(timeout))?;
                let writer = stream.try_clone()?;
                Ok(Connection { reader: BufReader::new(stream), writer })
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
        // Bytes, not `read_line`: a value in another encoding than UTF-8 must not fail the poll.
        let mut bytes = Vec::new();
        let read =
            self.reader.read_until(b'\n', &mut bytes).map_err(|e| ClientError::Unreachable(describe(&e)))?;
        if read == 0 {
            return Err(ClientError::Unreachable("connection closed by the server".into()));
        }
        let line = String::from_utf8_lossy(&bytes);
        match parse_line(line.trim_end_matches('\n'))? {
            Line::Err(code) if code == "DATA-STALE" || code == "DRIVER-NOT-CONNECTED" => {
                Err(ClientError::NoData(code))
            }
            Line::Err(code) => Err(ClientError::Server(code)),
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
