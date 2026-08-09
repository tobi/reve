//! Durable heartbeat schedule loading and response validation.

use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::path::Path;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum HeartbeatError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("yaml: {0}")]
    Yaml(#[from] serde_yaml::Error),
    #[error("invalid heartbeat response: {0}")]
    Response(String),
}
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct Schedule {
    #[serde(default)]
    pub tasks: Vec<Task>,
}
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct Task {
    pub name: String,
    pub every: String,
    pub lane: Option<String>,
    pub prompt: String,
    pub delivery: Option<String>,
    pub continue_lane: Option<bool>,
}
#[derive(Debug, Clone)]
pub struct Reloaded {
    pub schedule: Schedule,
    pub fingerprint: String,
    pub changed: bool,
}

pub fn load(path: &Path, previous: Option<&str>) -> Result<Reloaded, HeartbeatError> {
    let text = std::fs::read_to_string(path)?;
    let schedule: Schedule = serde_yaml::from_str(&text)?;
    let mut h = Sha256::new();
    h.update(text.as_bytes());
    let fp = h
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    Ok(Reloaded {
        changed: previous != Some(&fp),
        schedule,
        fingerprint: fp,
    })
}
pub fn response(text: &str) -> Result<Option<String>, HeartbeatError> {
    let t = text.trim();
    if t == "SILENCE" {
        return Ok(None);
    }
    if let Some(v) = t.strip_prefix("Message: ")
        && !v.trim().is_empty()
    {
        return Ok(Some(v.to_string()));
    }
    if let Some(v) = t.strip_prefix("Steer: ")
        && !v.trim().is_empty()
    {
        return Ok(Some(v.to_string()));
    }
    Err(HeartbeatError::Response(t.into()))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reload_only_changes_when_file_changes() {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("HEARTBEAT.yml");
        std::fs::write(
            &p,
            "tasks:\n  - name: check\n    every: 30m\n    prompt: Check\n",
        )
        .unwrap();
        let a = load(&p, None).unwrap();
        let b = load(&p, Some(&a.fingerprint)).unwrap();
        assert!(a.changed);
        assert!(!b.changed);
        assert_eq!(a.schedule.tasks[0].name, "check");
    }
    #[test]
    fn response_contract_is_strict() {
        assert_eq!(response("SILENCE").unwrap(), None);
        assert_eq!(response("Message: hi").unwrap(), Some("hi".into()));
        assert_eq!(response("Steer: do it").unwrap(), Some("do it".into()));
        assert!(response("maybe").is_err());
    }
}
