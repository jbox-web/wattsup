//! The configuration file shared by the app and the CLI.
//!
//! ```toml
//! poll_interval_seconds = 30
//!
//! [[ups]]
//! name = "Home"
//! host = "192.0.2.10"
//! ups = "ups"
//! ```

use std::collections::HashSet;
use std::ffi::OsString;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const DEFAULT_PORT: u16 = 3493;
pub const DEFAULT_POLL_INTERVAL_SECONDS: u32 = 30;
pub const MIN_POLL_INTERVAL_SECONDS: u32 = 5;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpsEntry {
    /// Display name; unique, also the key of the Keychain entry and of the CLI.
    pub name: String,
    pub host: String,
    #[serde(default = "default_port")]
    pub port: u16,
    /// The UPS name on the NUT server.
    pub ups: String,
    /// Show this UPS in the macOS Batteries widget.
    #[serde(default = "yes")]
    pub publish: bool,
    #[serde(default = "yes")]
    pub notify_unreachable: bool,
    /// NUT username; the password lives in the Keychain, never here.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    #[serde(default = "default_poll_interval")]
    pub poll_interval_seconds: u32,
    #[serde(default)]
    pub ups: Vec<UpsEntry>,
}

impl Default for Config {
    fn default() -> Config {
        Config { poll_interval_seconds: DEFAULT_POLL_INTERVAL_SECONDS, ups: Vec::new() }
    }
}

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("cannot read {path}: {source}")]
    Read { path: PathBuf, source: io::Error },
    #[error("{path}: {message}")]
    Parse { path: PathBuf, message: String },
    #[error("invalid configuration: {0}")]
    Invalid(String),
    #[error("cannot write {path}: {source}")]
    Write { path: PathBuf, source: io::Error },
}

/// `$XDG_CONFIG_HOME/wattsup/config.toml`, else `~/.config/wattsup/config.toml`.
pub fn default_path() -> PathBuf {
    path_under(std::env::var_os("XDG_CONFIG_HOME"), dirs::home_dir().unwrap_or_default().into_os_string())
}

fn path_under(xdg_config_home: Option<OsString>, home: OsString) -> PathBuf {
    let base = match xdg_config_home {
        Some(dir) if !dir.is_empty() => PathBuf::from(dir),
        _ => PathBuf::from(home).join(".config"),
    };
    base.join("wattsup").join("config.toml")
}

/// The Keychain service that holds the NUT password of an entry.
pub fn keychain_service(name: &str) -> String {
    format!("jbox.wattsup.{name}")
}

impl Config {
    /// A missing or empty file is an empty configuration.
    pub fn load(path: &Path) -> Result<Config, ConfigError> {
        let text = match fs::read_to_string(path) {
            Ok(text) => text,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Config::default()),
            Err(source) => return Err(ConfigError::Read { path: path.to_path_buf(), source }),
        };
        let config: Config = toml::from_str(&text).map_err(|error| ConfigError::Parse {
            path: path.to_path_buf(),
            // Only the position and the reason: the offending line could hold a secret, and
            // toml quotes the value it rejects ("invalid type: string \"...\"").
            message: match error.span() {
                Some(span) => {
                    format!("line {}: {}", line_of(&text, span.start), without_quotes(error.message()))
                }
                None => without_quotes(error.message()),
            },
        })?;
        config.validate().map_err(|error| match error {
            ConfigError::Invalid(message) => ConfigError::Invalid(format!("{}: {message}", path.display())),
            other => other,
        })?;
        Ok(config)
    }

    /// Validates, then replaces the file in one step. A path that is a symbolic link (to a
    /// synced folder, say) stays one: the file it points to is the one replaced.
    pub fn save(&self, path: &Path) -> Result<(), ConfigError> {
        self.validate()?;
        let text = toml::to_string_pretty(self).map_err(|error| ConfigError::Invalid(error.to_string()))?;
        let write_error = |source| ConfigError::Write { path: path.to_path_buf(), source };
        let target = match fs::symlink_metadata(path) {
            // The link's own target, read rather than resolved: it may not exist yet.
            Ok(metadata) if metadata.file_type().is_symlink() => {
                let link = fs::read_link(path).map_err(write_error)?;
                match path.parent() {
                    Some(parent) if link.is_relative() => parent.join(link),
                    _ => link,
                }
            }
            _ => path.to_path_buf(),
        };
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(write_error)?;
        }
        // A name of its own, so that two saves at once do not write the same temporary file.
        let temporary = target.with_extension(format!("toml.{}.tmp", std::process::id()));
        let written = fs::File::create(&temporary).and_then(|mut file| {
            io::Write::write_all(&mut file, text.as_bytes())?;
            file.sync_all()
        });
        if let Err(source) = written.and_then(|()| fs::rename(&temporary, &target)) {
            let _ = fs::remove_file(&temporary);
            return Err(write_error(source));
        }
        Ok(())
    }

    pub fn validate(&self) -> Result<(), ConfigError> {
        if self.poll_interval_seconds < MIN_POLL_INTERVAL_SECONDS {
            return Err(ConfigError::Invalid(format!(
                "the poll interval must be at least {MIN_POLL_INTERVAL_SECONDS} seconds"
            )));
        }
        let mut names = HashSet::new();
        for entry in &self.ups {
            let name = entry.name.trim();
            if name.is_empty() {
                return Err(ConfigError::Invalid("a UPS has no name".into()));
            }
            if entry.host.trim().is_empty() {
                return Err(ConfigError::Invalid(format!("\"{name}\" has no host")));
            }
            if entry.ups.trim().is_empty() {
                return Err(ConfigError::Invalid(format!("\"{name}\" has no NUT UPS name")));
            }
            let fields = [Some(&entry.name), Some(&entry.host), Some(&entry.ups), entry.username.as_ref()];
            if fields.into_iter().flatten().any(|field| field.chars().any(char::is_control)) {
                return Err(ConfigError::Invalid(format!(
                    "\"{}\" has a line break or a control character in a field",
                    name.escape_debug()
                )));
            }
            if entry.port == 0 {
                return Err(ConfigError::Invalid(format!("\"{name}\" has port 0")));
            }
            if !names.insert(name.to_lowercase()) {
                return Err(ConfigError::Invalid(format!("two UPSes are named \"{name}\"")));
            }
        }
        Ok(())
    }
}

/// The message with every quoted part masked.
fn without_quotes(message: &str) -> String {
    let mut masked = String::new();
    let mut quoted = false;
    let mut chars = message.chars();
    while let Some(c) = chars.next() {
        if quoted && c == '\\' {
            // An escaped character, a quote included, belongs to the value.
            chars.next();
        } else if c == '"' {
            if !quoted {
                masked.push_str("\"…\"");
            }
            quoted = !quoted;
        } else if !quoted {
            masked.push(c);
        }
    }
    masked
}

fn line_of(text: &str, offset: usize) -> usize {
    text[..offset.min(text.len())].matches('\n').count() + 1
}

fn default_port() -> u16 {
    DEFAULT_PORT
}

fn default_poll_interval() -> u32 {
    DEFAULT_POLL_INTERVAL_SECONDS
}

fn yes() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    const EXAMPLE: &str = r#"poll_interval_seconds = 30

[[ups]]
name = "Maison"
host = "192.0.2.10"
ups = "ups"
"#;

    fn entry(name: &str) -> UpsEntry {
        UpsEntry {
            name: name.into(),
            host: "nas.example".into(),
            port: 3493,
            ups: "ups".into(),
            publish: true,
            notify_unreachable: true,
            username: None,
        }
    }

    fn config(entries: Vec<UpsEntry>) -> Config {
        Config { poll_interval_seconds: 30, ups: entries }
    }

    fn write(content: &str) -> (tempfile::TempDir, std::path::PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        fs::write(&path, content).unwrap();
        (dir, path)
    }

    #[test]
    fn a_missing_file_is_an_empty_configuration() {
        let dir = tempfile::tempdir().unwrap();
        let loaded = Config::load(&dir.path().join("absent.toml")).unwrap();
        assert_eq!(loaded, Config { poll_interval_seconds: 30, ups: vec![] });
    }

    #[test]
    fn an_empty_file_is_an_empty_configuration() {
        let (_dir, path) = write("");
        assert_eq!(Config::load(&path).unwrap(), Config { poll_interval_seconds: 30, ups: vec![] });
    }

    #[test]
    fn fills_the_defaults_of_an_entry() {
        let (_dir, path) = write(EXAMPLE);
        let loaded = Config::load(&path).unwrap();
        assert_eq!(loaded.poll_interval_seconds, 30);
        assert_eq!(
            loaded.ups,
            vec![UpsEntry {
                name: "Maison".into(),
                host: "192.0.2.10".into(),
                port: 3493,
                ups: "ups".into(),
                publish: true,
                notify_unreachable: true,
                username: None,
            }]
        );
    }

    #[test]
    fn reads_every_field() {
        let (_dir, path) = write(
            r#"poll_interval_seconds = 60

[[ups]]
name = "Bureau"
host = "nas2.example"
port = 3500
ups = "apc"
publish = false
notify_unreachable = false
username = "monuser"
"#,
        );
        let loaded = Config::load(&path).unwrap();
        assert_eq!(loaded.poll_interval_seconds, 60);
        let ups = &loaded.ups[0];
        assert_eq!((ups.port, ups.publish, ups.notify_unreachable), (3500, false, false));
        assert_eq!(ups.username.as_deref(), Some("monuser"));
    }

    #[test]
    fn an_invalid_file_names_its_path_and_line() {
        let (_dir, path) = write("poll_interval_seconds = 30\n\n[[ups]\nname = \"x\"\n");
        let message = Config::load(&path).unwrap_err().to_string();
        assert!(message.contains(path.to_str().unwrap()), "{message}");
        assert!(message.contains("line 3"), "{message}");
    }

    #[test]
    fn a_password_in_the_file_is_refused() {
        let (_dir, path) = write(&format!("{EXAMPLE}password = \"secret\"\n"));
        let error = Config::load(&path).unwrap_err();
        assert!(matches!(error, ConfigError::Parse { .. }), "{error:?}");
        assert!(!error.to_string().contains("secret"), "{error}");
    }

    #[test]
    fn saving_then_loading_gives_the_same_configuration() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.toml");
        let mut second = entry("Bureau");
        second.username = Some("monuser".into());
        second.publish = false;
        let original = Config { poll_interval_seconds: 45, ups: vec![entry("Maison"), second] };
        original.save(&path).unwrap();
        assert_eq!(Config::load(&path).unwrap(), original);
    }

    #[test]
    fn saving_creates_the_parent_directory_and_leaves_no_temporary_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested").join("wattsup").join("config.toml");
        config(vec![entry("Maison")]).save(&path).unwrap();
        let names: Vec<String> = fs::read_dir(path.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        assert_eq!(names, vec!["config.toml"]);
    }

    #[test]
    fn saving_an_invalid_configuration_leaves_the_file_untouched() {
        let (_dir, path) = write(EXAMPLE);
        let error = config(vec![entry("Maison"), entry("maison")]).save(&path).unwrap_err();
        assert!(matches!(error, ConfigError::Invalid(_)), "{error:?}");
        assert_eq!(fs::read_to_string(&path).unwrap(), EXAMPLE);
    }

    #[test]
    fn refuses_two_entries_with_the_same_name_whatever_the_case() {
        let error = config(vec![entry("Maison"), entry("MAISON")]).validate().unwrap_err();
        assert!(error.to_string().to_lowercase().contains("maison"), "{error}");
    }

    #[test]
    fn refuses_empty_fields_a_zero_port_and_a_short_interval() {
        let mut no_name = entry("");
        no_name.name = "  ".into();
        let mut no_host = entry("A");
        no_host.host = String::new();
        let mut no_ups = entry("A");
        no_ups.ups = String::new();
        let mut no_port = entry("A");
        no_port.port = 0;
        for bad in [no_name, no_host, no_ups, no_port] {
            assert!(config(vec![bad.clone()]).validate().is_err(), "{bad:?}");
        }
        assert!(Config { poll_interval_seconds: 4, ups: vec![] }.validate().is_err());
        assert!(Config { poll_interval_seconds: 5, ups: vec![entry("A")] }.validate().is_ok());
    }

    #[test]
    fn a_semantically_invalid_file_names_its_path() {
        let (_dir, path) = write("poll_interval_seconds = 2\n");
        let message = Config::load(&path).unwrap_err().to_string();
        assert!(message.contains(path.to_str().unwrap()), "{message}");
        assert!(message.contains("at least 5 seconds"), "{message}");
    }

    #[test]
    fn loading_an_invalid_configuration_fails() {
        let (_dir, path) =
            write(&format!("{EXAMPLE}\n[[ups]]\nname = \"maison\"\nhost = \"h\"\nups = \"u\"\n"));
        assert!(matches!(Config::load(&path).unwrap_err(), ConfigError::Invalid(_)));
    }

    #[test]
    fn a_type_error_does_not_echo_the_value() {
        let (_dir, path) =
            write("[[ups]]\nname = \"Maison\"\nhost = \"h\"\nups = \"u\"\nport = \"hunter2\"\n");
        let message = Config::load(&path).unwrap_err().to_string();
        assert!(message.contains("line 5"), "{message}");
        assert!(!message.contains("hunter2"), "{message}");
    }

    #[test]
    fn a_rejected_value_with_an_escaped_quote_is_masked_too() {
        let (_dir, path) =
            write("[[ups]]\nname = \"Maison\"\nhost = \"h\"\nups = \"u\"\nport = 'ab\"cd hunter2'\n");
        let message = Config::load(&path).unwrap_err().to_string();
        assert!(!message.contains("hunter2"), "{message}");
        assert!(!message.contains("cd"), "{message}");
    }

    #[cfg(unix)]
    #[test]
    fn saving_through_a_link_to_a_file_not_there_yet_creates_the_target() {
        let dir = tempfile::tempdir().unwrap();
        fs::create_dir_all(dir.path().join("synced")).unwrap();
        let link = dir.path().join("config.toml");
        // A relative link, to a file that does not exist yet.
        std::os::unix::fs::symlink("synced/config.toml", &link).unwrap();

        config(vec![entry("Bureau")]).save(&link).unwrap();

        assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        assert_eq!(Config::load(&dir.path().join("synced/config.toml")).unwrap().ups[0].name, "Bureau");
    }

    #[test]
    fn refuses_line_breaks_and_control_characters() {
        let mut bad_name = entry("A");
        bad_name.name = "A\nB".into();
        let mut bad_ups = entry("A");
        bad_ups.ups = "ups\rLIST UPS".into();
        let mut bad_user = entry("A");
        bad_user.username = Some("monuser\nLIST UPS".into());
        let mut bad_host = entry("A");
        bad_host.host = "nas\t.example".into();
        for bad in [bad_name, bad_ups, bad_user, bad_host] {
            assert!(config(vec![bad.clone()]).validate().is_err(), "{bad:?}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn saving_through_a_symlink_keeps_the_link_and_updates_its_target() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("synced").join("config.toml");
        fs::create_dir_all(target.parent().unwrap()).unwrap();
        fs::write(&target, EXAMPLE).unwrap();
        let link = dir.path().join("config.toml");
        std::os::unix::fs::symlink(&target, &link).unwrap();

        config(vec![entry("Bureau")]).save(&link).unwrap();

        assert!(fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        assert_eq!(Config::load(&target).unwrap().ups[0].name, "Bureau");
        let names: Vec<String> = fs::read_dir(target.parent().unwrap())
            .unwrap()
            .map(|e| e.unwrap().file_name().into_string().unwrap())
            .collect();
        assert_eq!(names, vec!["config.toml"]);
    }

    #[test]
    fn names_the_keychain_service_after_the_entry() {
        assert_eq!(keychain_service("Maison"), "jbox.wattsup.Maison");
    }

    #[test]
    fn the_default_path_follows_xdg_config_home() {
        assert_eq!(
            path_under(Some("/tmp/xdg".into()), "/Users/me".into()),
            PathBuf::from("/tmp/xdg/wattsup/config.toml")
        );
        assert_eq!(
            path_under(None, "/Users/me".into()),
            PathBuf::from("/Users/me/.config/wattsup/config.toml")
        );
        assert_eq!(
            path_under(Some("".into()), "/Users/me".into()),
            PathBuf::from("/Users/me/.config/wattsup/config.toml")
        );
    }
}
