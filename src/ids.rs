//! Identifier allocation.
//!
//! Every id — entry, usage row, operation — is a **UUIDv7** (`docs/harness.md`
//! §1.2): the first 48 bits are the mint time in milliseconds, the rest is
//! random. Ids are therefore self-describing and time-sortable, and a
//! *follower* id can be minted with its leader's timestamp so a tool call and
//! its results share one time prefix even across a midnight boundary.
//!
//! Ids are minted *before* the effect they name. An `effect_pending` state
//! carries the id of the entry that does not exist yet, so recovery can tell
//! "never ran" from "ran, result lost" without guessing.

use std::fmt;

use serde::{Deserialize, Serialize};

/// Milliseconds since the epoch, the timestamp every row carries.
pub fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

/// Mint a UUIDv7 string for the given millisecond timestamp.
pub fn uuid_v7(timestamp_ms: i64) -> String {
    let ts = (timestamp_ms.max(0) as u64) & 0x0000_FFFF_FFFF_FFFF;
    let rand_a: u16 = rand::random::<u16>() & 0x0FFF;
    let rand_b: u64 = rand::random::<u64>() & 0x3FFF_FFFF_FFFF_FFFF;
    let hi: u64 = (ts << 16) | 0x7000 | rand_a as u64;
    let lo: u64 = 0x8000_0000_0000_0000 | rand_b;
    format!(
        "{:08x}-{:04x}-{:04x}-{:04x}-{:012x}",
        hi >> 32,
        (hi >> 16) & 0xFFFF,
        hi & 0xFFFF,
        lo >> 48,
        lo & 0x0000_FFFF_FFFF_FFFF
    )
}

/// The 48-bit mint timestamp of a UUIDv7, if the string is one.
pub fn uuid_timestamp(id: &str) -> Option<i64> {
    let hex: String = id.chars().filter(|c| *c != '-').take(12).collect();
    if hex.len() != 12 {
        return None;
    }
    i64::from_str_radix(&hex, 16).ok()
}

/// Declares an id newtype over a UUIDv7 string.
macro_rules! id_type {
    ($name:ident, $doc:literal) => {
        #[doc = $doc]
        #[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(pub String);

        impl $name {
            /// A fresh id minted now.
            pub fn new() -> Self {
                Self(uuid_v7(now_ms()))
            }

            /// A follower: fresh random tail, the leader's timestamp.
            pub fn follower_of(leader: &str) -> Self {
                Self(uuid_v7(uuid_timestamp(leader).unwrap_or_else(now_ms)))
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl Default for $name {
            fn default() -> Self {
                Self::new()
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }

        impl From<String> for $name {
            fn from(value: String) -> Self {
                Self(value)
            }
        }

        impl From<&str> for $name {
            fn from(value: &str) -> Self {
                Self(value.to_string())
            }
        }
    };
}

id_type!(EntryId, "Identifies a conversation-tree entry.");
id_type!(UsageId, "Identifies a usage-ledger row.");
id_type!(
    OpId,
    "Identifies one operation on a lane (the public `runId`)."
);

/// A short, human-scannable, prefixed id. Used for correlation handles that
/// are not durable identities — a turn, a structural task — where an operator
/// reading a log matters more than global uniqueness.
pub fn short_id(prefix: &str) -> String {
    format!("{prefix}_{}", &uuid_v7(now_ms()).replace('-', "")[..12])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_uuid_v7_and_unique() {
        let a = EntryId::new();
        let b = EntryId::new();
        assert_eq!(a.as_str().len(), 36, "got {a}");
        assert_eq!(a.as_str().as_bytes()[14], b'7', "version nibble: {a}");
        assert_ne!(a, b);
    }

    #[test]
    fn ids_sort_by_mint_time() {
        let early = uuid_v7(1_000);
        let late = uuid_v7(2_000);
        assert!(early < late);
        assert_eq!(uuid_timestamp(&early), Some(1_000));
    }

    #[test]
    fn a_follower_shares_its_leaders_timestamp() {
        let leader = uuid_v7(1_700_000_000_000);
        let follower = EntryId::follower_of(&leader);
        assert_eq!(
            uuid_timestamp(follower.as_str()),
            Some(1_700_000_000_000),
            "{follower}"
        );
        assert_ne!(follower.as_str(), leader);
    }

    #[test]
    fn ids_round_trip_as_bare_strings() {
        let id = EntryId::from("abc");
        assert_eq!(serde_json::to_string(&id).unwrap(), "\"abc\"");
        let back: EntryId = serde_json::from_str("\"abc\"").unwrap();
        assert_eq!(back, id);
    }
}
