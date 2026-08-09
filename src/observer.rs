//! Snapshot plus gapless passive events.

use crate::session::{Event, Snapshot};
use tokio::sync::broadcast;

#[derive(Clone)]
pub struct Observer {
    tx: broadcast::Sender<Event>,
}
impl Observer {
    pub fn new(capacity: usize) -> Self {
        let (tx, _) = broadcast::channel(capacity);
        Self { tx }
    }
    pub fn publish(&self, event: Event) {
        let _ = self.tx.send(event);
    }
    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.tx.subscribe()
    }
    pub fn snapshot(&self, snapshot: Snapshot) {
        self.publish(Event::Snapshot(snapshot));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn subscribers_receive_ordered_events() {
        let hub = Observer::new(8);
        let mut rx = hub.subscribe();
        hub.publish(Event::Snapshot(Snapshot {
            seq: 1,
            lane: "main".into(),
            leaf: None,
            entries: 0,
            records: 1,
        }));
        hub.publish(Event::Finished {
            outcome: crate::records::Outcome::Completed,
        });
        assert!(matches!(rx.recv().await.unwrap(), Event::Snapshot(_)));
        assert!(matches!(rx.recv().await.unwrap(), Event::Finished { .. }));
    }
}
