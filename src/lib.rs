//! Reve: a durable coding agent.
//!
//! The core is Rust; the scripting surface an agent author touches — its
//! configuration, project tools, sandbox policy, and channels — is Lua.
//! Everything a model authors runs inside a microVM. There is no host-shell
//! path anywhere in this crate.

pub mod channels;
pub mod compaction;
pub mod entry;
pub mod events;
pub mod harness;
pub mod heartbeat;
pub mod hooks;
pub mod ids;
pub mod lane;
pub mod lua;
pub mod model;
pub mod progress;
pub mod project;
pub mod provider;
pub mod sandbox;
pub mod session;
pub mod skills;
pub mod state;
pub mod storage;
pub mod theme;
pub mod tools;
pub mod tui;
