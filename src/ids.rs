//! Identifier allocation.
//!
//! Ids are provisioned *before* the effect they name. A `tool_started` record
//! carries the id of the result entry that does not exist yet, so recovery can
//! tell "never ran" from "ran, result lost" without guessing.

use std::fmt;

use serde::{Deserialize, Serialize};

const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyz0123456789";

fn token(len: usize) -> String {
    (0..len)
        .map(|_| ALPHABET[rand::random_range(0..ALPHABET.len())] as char)
        .collect()
}

/// Declares a prefixed id newtype: `e_`, `r_`, `run_`.
macro_rules! id_type {
    ($name:ident, $prefix:literal, $doc:literal) => {
        #[doc = $doc]
        #[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(pub String);

        impl $name {
            /// A fresh id. 16 characters of base-36 is comfortably beyond
            /// collision range for one session's worth of entries.
            pub fn new() -> Self {
                Self(format!("{}{}", $prefix, token(16)))
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

id_type!(EntryId, "e_", "Identifies a conversation-tree entry.");
id_type!(RecordId, "r_", "Identifies a metadata record.");
id_type!(RunId, "run_", "Identifies one run of a lane operation.");

/// Milliseconds since the epoch, the timestamp every record carries.
pub fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_are_prefixed_and_unique() {
        let a = EntryId::new();
        let b = EntryId::new();
        assert!(a.as_str().starts_with("e_"), "got {a}");
        assert_eq!(a.as_str().len(), 18);
        assert_ne!(a, b);
        assert!(RecordId::new().as_str().starts_with("r_"));
        assert!(RunId::new().as_str().starts_with("run_"));
    }

    #[test]
    fn ids_round_trip_as_bare_strings() {
        let id = EntryId::from("e_abc");
        assert_eq!(serde_json::to_string(&id).unwrap(), "\"e_abc\"");
        let back: EntryId = serde_json::from_str("\"e_abc\"").unwrap();
        assert_eq!(back, id);
    }
}
