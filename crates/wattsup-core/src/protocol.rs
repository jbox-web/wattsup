//! One line of a NUT server reply.
//!
//! From the "Network protocol information" chapter of the NUT developer guide.
//! The protocol is ASCII, line-oriented, each line ended by a single `\n`.
//! Forms used here:
//!
//! ```text
//! BEGIN LIST UPS            BEGIN LIST VAR <upsname>
//! UPS <upsname> "<desc>"    VAR <upsname> <varname> "<value>"
//! END LIST UPS              END LIST VAR <upsname>
//! OK [<extra>...]           ERR <message> [<extra>...]
//! ```
//!
//! `<message>` is one element without spaces (`DATA-STALE`, `ACCESS-DENIED`, ...).
//! Multi-word elements are in double quotes; an embedded quote is escaped with a
//! backslash, an embedded backslash is written `\\`.

use thiserror::Error;

/// A parsed reply line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Line {
    Var {
        ups: String,
        name: String,
        value: String,
    },
    Ups {
        name: String,
        description: String,
    },
    BeginList,
    EndList,
    Ok,
    /// The error code, e.g. `DATA-STALE`.
    Err(String),
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ProtocolError {
    #[error("unterminated quote in server reply")]
    UnterminatedQuote,
    #[error("unexpected server reply: {0}")]
    Unexpected(String),
}

/// Parses one reply line, without its line terminator.
pub fn parse_line(line: &str) -> Result<Line, ProtocolError> {
    let elements = split_elements(line.trim_end_matches('\r'))?;
    let words: Vec<&str> = elements.iter().map(String::as_str).collect();
    match words.as_slice() {
        ["VAR", ups, name, value] => {
            Ok(Line::Var { ups: ups.to_string(), name: name.to_string(), value: value.to_string() })
        }
        ["UPS", name, description] => {
            Ok(Line::Ups { name: name.to_string(), description: description.to_string() })
        }
        ["BEGIN", "LIST", ..] => Ok(Line::BeginList),
        ["END", "LIST", ..] => Ok(Line::EndList),
        ["OK", ..] => Ok(Line::Ok),
        ["ERR", code, ..] => Ok(Line::Err(code.to_string())),
        _ => Err(ProtocolError::Unexpected(line.to_string())),
    }
}

/// Splits a line into elements: words, or quoted strings with `\"` and `\\` unescaped.
fn split_elements(line: &str) -> Result<Vec<String>, ProtocolError> {
    let mut elements = Vec::new();
    let mut chars = line.chars().peekable();
    loop {
        while chars.next_if(|c| *c == ' ').is_some() {}
        let Some(&first) = chars.peek() else { break };
        let quoted = first == '"';
        if quoted {
            chars.next();
        }
        let mut element = String::new();
        let mut closed = !quoted;
        while let Some(c) = chars.next() {
            match c {
                '\\' => element.extend(chars.next()),
                '"' if quoted => {
                    closed = true;
                    break;
                }
                ' ' if !quoted => break,
                _ => element.push(c),
            }
        }
        if !closed {
            return Err(ProtocolError::UnterminatedQuote);
        }
        elements.push(element);
    }
    Ok(elements)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn value(line: &str) -> String {
        match parse_line(line).unwrap() {
            Line::Var { value, .. } => value,
            other => panic!("not a VAR: {other:?}"),
        }
    }

    #[test]
    fn parses_a_variable() {
        assert_eq!(
            parse_line(r#"VAR ups battery.charge "100""#).unwrap(),
            Line::Var { ups: "ups".into(), name: "battery.charge".into(), value: "100".into() }
        );
    }

    #[test]
    fn keeps_spaces_inside_a_value() {
        assert_eq!(value(r#"VAR ups device.model "Back-UPS BX950MI ""#), "Back-UPS BX950MI ");
    }

    #[test]
    fn unescapes_quotes() {
        assert_eq!(value(r#"VAR ups x "a \"b\" c""#), r#"a "b" c"#);
    }

    #[test]
    fn unescapes_backslashes() {
        assert_eq!(value(r#"VAR ups x "c:\\d""#), r"c:\d");
    }

    #[test]
    fn accepts_an_empty_value() {
        assert_eq!(value(r#"VAR ups x """#), "");
    }

    #[test]
    fn parses_a_ups_entry() {
        assert_eq!(
            parse_line(r#"UPS ups "Garage""#).unwrap(),
            Line::Ups { name: "ups".into(), description: "Garage".into() }
        );
    }

    #[test]
    fn parses_an_error_code() {
        assert_eq!(parse_line("ERR DATA-STALE").unwrap(), Line::Err("DATA-STALE".into()));
    }

    #[test]
    fn drops_the_extra_words_of_an_error() {
        assert_eq!(parse_line("ERR UNKNOWN-UPS some detail").unwrap(), Line::Err("UNKNOWN-UPS".into()));
    }

    #[test]
    fn parses_list_boundaries() {
        assert_eq!(parse_line("BEGIN LIST VAR ups").unwrap(), Line::BeginList);
        assert_eq!(parse_line("END LIST VAR ups").unwrap(), Line::EndList);
        assert_eq!(parse_line("BEGIN LIST UPS").unwrap(), Line::BeginList);
        assert_eq!(parse_line("END LIST UPS").unwrap(), Line::EndList);
    }

    #[test]
    fn parses_ok_with_or_without_extra() {
        assert_eq!(parse_line("OK").unwrap(), Line::Ok);
        assert_eq!(parse_line("OK Goodbye").unwrap(), Line::Ok);
    }

    #[test]
    fn ignores_a_trailing_carriage_return() {
        assert_eq!(parse_line("OK\r").unwrap(), Line::Ok);
    }

    #[test]
    fn rejects_an_unterminated_quote() {
        assert!(parse_line(r#"VAR ups x "unterminated"#).is_err());
    }

    #[test]
    fn rejects_an_unknown_line() {
        assert!(parse_line("GARBAGE").is_err());
    }

    #[test]
    fn rejects_a_variable_without_value() {
        assert!(parse_line("VAR ups battery.charge").is_err());
    }

    #[test]
    fn rejects_an_empty_line() {
        assert!(parse_line("").is_err());
    }
}
