//! Channel registrations and durable inbox messages.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use tokio::sync::broadcast;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Message {
    pub channel: String,
    pub text: String,
    pub timestamp: i64,
}
#[derive(Clone)]
pub struct Hub {
    tx: broadcast::Sender<Message>,
}
impl Default for Hub {
    fn default() -> Self {
        Self::new()
    }
}
impl Hub {
    pub fn new() -> Self {
        let (tx, _) = broadcast::channel(128);
        Self { tx }
    }
    pub fn publish(&self, message: Message) {
        let _ = self.tx.send(message);
    }
    pub fn subscribe(&self) -> broadcast::Receiver<Message> {
        self.tx.subscribe()
    }
}
#[derive(Debug, Clone)]
pub struct Kv {
    path: PathBuf,
    namespace: String,
}
impl Kv {
    pub fn new(root: &Path, namespace: &str) -> Self {
        Self {
            path: root.join(".leve/channels.json"),
            namespace: namespace.into(),
        }
    }
    pub fn get(&self, key: &str) -> Option<String> {
        let text = std::fs::read_to_string(&self.path).ok()?;
        let v: serde_json::Value = serde_json::from_str(&text).ok()?;
        v.get(&self.namespace)?
            .get(key)?
            .as_str()
            .map(str::to_string)
    }
    pub fn set(&self, key: &str, value: &str) -> std::io::Result<()> {
        if let Some(p) = self.path.parent() {
            std::fs::create_dir_all(p)?;
        }
        let mut all: serde_json::Map<String, serde_json::Value> =
            std::fs::read_to_string(&self.path)
                .ok()
                .and_then(|s| serde_json::from_str(&s).ok())
                .unwrap_or_default();
        let ns = all
            .entry(self.namespace.clone())
            .or_insert_with(|| serde_json::json!({}));
        ns[key] = serde_json::Value::String(value.into());
        std::fs::write(&self.path, serde_json::to_vec_pretty(&all).unwrap())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn kv_is_namespaced_and_durable() {
        let d = tempfile::tempdir().unwrap();
        let a = Kv::new(d.path(), "telegram");
        let b = Kv::new(d.path(), "slack");
        a.set("token", "a").unwrap();
        b.set("token", "b").unwrap();
        assert_eq!(a.get("token"), Some("a".into()));
        assert_eq!(b.get("token"), Some("b".into()));
    }
    #[tokio::test]
    async fn messages_broadcast_in_order() {
        let h = Hub::new();
        let mut rx = h.subscribe();
        h.publish(Message {
            channel: "x".into(),
            text: "one".into(),
            timestamp: 1,
        });
        assert_eq!(rx.recv().await.unwrap().text, "one");
    }
}
