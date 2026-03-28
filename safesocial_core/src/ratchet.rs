//! Double Ratchet session management for Forward Secrecy.
//!
//! Provides the ratcheting logic for pairwise communication sessions.
//! Each session maintains its own chain keys and derives ephemeral message
//! keys that are destroyed after use.

use std::collections::HashMap;
use serde::{Deserialize, Serialize};
use double_ratchet::DHEKeyPair;
use double_ratchet::Session as RatchetSession;

/// Wrapper for a Double Ratchet session that is serializable.
#[derive(Serialize, Deserialize)]
pub struct SpheresSession {
    pub contact_public_key: String,
    // The double-ratchet crate's Session is not serializable by default
    // so we would need to manually serialize its state or use a different crate.
    // For now, we will store the raw bytes if possible.
    pub session_data: Vec<u8>,
}

impl SpheresSession {
    pub fn new(contact_public_key: &str, _initial_secret: [u8; 32]) -> Self {
        // Placeholder: in a real implementation, we would initialize the ratchet here
        Self {
            contact_public_key: contact_public_key.to_string(),
            session_data: Vec::new(),
        }
    }
}

/// Manages multiple ratchet sessions.
pub struct RatchetManager {
    sessions: HashMap<String, SpheresSession>,
}

impl RatchetManager {
    pub fn new() -> Self {
        Self {
            sessions: HashMap::new(),
        }
    }

    pub fn get_session(&mut self, contact_public_key: &str) -> Option<&mut SpheresSession> {
        self.sessions.get_mut(contact_public_key)
    }

    pub fn add_session(&mut self, session: SpheresSession) {
        self.sessions.insert(session.contact_public_key.clone(), session);
    }
}
