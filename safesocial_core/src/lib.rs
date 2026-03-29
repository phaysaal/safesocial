//! Spheres P2P social network core library.
//!
//! This crate provides the Veilid-based backend for Spheres, a decentralized
//! peer-to-peer social network where all data stays on user devices. It handles
//! identity management, profile storage, messaging, group chats, feeds, and
//! media — all via Veilid's DHT and encrypted routing.

pub mod node;
pub mod identity;
pub mod schema;
pub mod profile;
pub mod contacts;
pub mod messaging;
pub mod groups;
pub mod feed;
pub mod media;
pub mod privacy;
pub mod ratchet;
pub mod recovery;
pub mod ffi;

use std::sync::Arc;
use veilid_core::*;
use crate::ratchet::SecureSessionManager;

/// Callback type for receiving Veilid network updates.
pub type UpdateCallback = Arc<dyn Fn(VeilidUpdate) + Send + Sync>;

/// Errors that can occur within the Spheres core library.
#[derive(Debug, thiserror::Error)]
pub enum SpheresError {
    /// An error originating from the Veilid API.
    #[error("Veilid error: {0}")]
    Veilid(#[from] VeilidAPIError),

    /// A serialization or deserialization error.
    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    /// The local identity was not found in the protected store.
    #[error("Identity not found")]
    IdentityNotFound,

    /// A requested DHT record was not found.
    #[error("Record not found: {0}")]
    RecordNotFound(String),

    /// A cryptographic operation failed.
    #[error("Crypto error: {0}")]
    CryptoError(String),

    /// A generic error with a descriptive message.
    #[error("{0}")]
    Generic(String),
}

/// A convenience Result type for Spheres operations.
pub type Result<T> = std::result::Result<T, SpheresError>;

/// The main entry point for the Spheres P2P network security logic.
///
/// `SpheresCore` manages the local identity and the secure session manager.
/// Note: Veilid node lifecycle is currently managed by the flutter app.
pub struct SpheresCore {
    identity: Option<KeyPair>,
    session_manager: SecureSessionManager,
}

impl SpheresCore {
    /// Initialize the Spheres core logic manager.
    pub async fn new(_state_dir: &str, _update_callback: UpdateCallback) -> Result<Self> {
        tracing::info!("Initializing Spheres core logic");

        Ok(Self {
            identity: None,
            session_manager: SecureSessionManager::new(),
        })
    }

    /// Gracefully shut down.
    pub async fn shutdown(self) -> Result<()> {
        tracing::info!("Shutting down Spheres core logic");
        Ok(())
    }

    /// Returns the local identity keypair, if one has been loaded or created.
    pub fn identity(&self) -> Option<&KeyPair> {
        self.identity.as_ref()
    }

    /// Sets the local identity keypair.
    pub fn set_identity(&mut self, keypair: KeyPair) {
        self.identity = Some(keypair);
    }

    /// Returns a mutable reference to the secure session manager.
    pub fn session_manager(&mut self) -> &mut SecureSessionManager {
        &mut self.session_manager
    }
}
