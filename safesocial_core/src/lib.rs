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

/// The main entry point for the Spheres P2P network.
///
/// `SpheresCore` manages the Veilid API lifecycle, routing context, and
/// the user's local identity. All higher-level operations (profiles, messaging,
/// contacts, etc.) use the API and routing context held here.
pub struct SpheresCore {
    api: VeilidAPI,
    routing_context: RoutingContext,
    identity: Option<KeyPair>,
    session_manager: SecureSessionManager,
}

impl SpheresCore {
    /// Initialize the Spheres core, starting the Veilid node.
    ///
    /// This builds the Veilid configuration, starts the API, attaches to the
    /// network, and creates a privacy-routed routing context with sequencing.
    ///
    /// # Arguments
    /// * `state_dir` — filesystem path where Veilid stores its tables, blocks, and secrets
    /// * `update_callback` — callback invoked on every Veilid network update
    pub async fn new(state_dir: &str, update_callback: UpdateCallback) -> Result<Self> {
        tracing::info!("Initializing Spheres core with state_dir={}", state_dir);

        let config_json = serde_json::json!({
            "program_name": "spheres",
            "namespace": "",
            "network": {
                "connection_initial_timeout_ms": 2000,
                "rpc": {
                    "concurrency": 0
                },
                "dht": {
                    "min_peer_count": 20
                }
            },
            "table_store": {
                "directory": format!("{}/table_store", state_dir),
            },
            "block_store": {
                "directory": format!("{}/block_store", state_dir),
            },
            "protected_store": {
                "directory": format!("{}/protected_store", state_dir),
            }
        });

        let config: VeilidConfig = serde_json::from_value(config_json)
            .map_err(SpheresError::Serialization)?;

        let api = api_startup(update_callback, config).await?;

        tracing::info!("Veilid API started, attaching to network");
        api.attach().await?;

        let routing_context = api
            .routing_context()?
            .with_default_safety()?
            .with_sequencing(Sequencing::PreferOrdered);

        tracing::info!("Routing context created with default safety and sequencing");

        Ok(Self {
            api,
            routing_context,
            identity: None,
            session_manager: SecureSessionManager::new(),
        })
    }

    /// Gracefully shut down the Veilid node.
    ///
    /// Detaches from the network and shuts down the API.
    pub async fn shutdown(self) -> Result<()> {
        tracing::info!("Shutting down Spheres core");
        self.api.detach().await?;
        self.api.shutdown().await;
        Ok(())
    }

    /// Returns a reference to the underlying Veilid API.
    pub fn api(&self) -> &VeilidAPI {
        &self.api
    }

    /// Returns a reference to the privacy-routed routing context.
    pub fn routing_context(&self) -> &RoutingContext {
        &self.routing_context
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
