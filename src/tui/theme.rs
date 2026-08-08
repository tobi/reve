//! The palette, shared with the rest of the crate.
//!
//! It lives at the crate root because startup progress is drawn before the
//! terminal exists and must still look like the same program.

pub use crate::theme::*;
