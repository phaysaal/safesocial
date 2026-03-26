//! Veilid node lifecycle management.
//!
//! Provides node start/stop, state tracking, and utilities for waiting
//! until the node is fully attached to the Veilid network.

use std::sync::{Arc, Mutex};
use std::time::Duration;
use veilid_core::*;

use crate::Result;

/// Represents the attachment state of the local Veilid node.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NodeState {
    /// Not connected to the network.
    Detached,
    /// In the process of joining the network.
    Attaching,
    /// Connected to some peers but not yet fully routable.
    Attached,
    /// Fully connected and routable on the Veilid network.
    FullyAttached,
    /// In the process of leaving the network.
    Detaching,
}

/// Manages the Veilid node's lifecycle and tracks its attachment state.
pub struct NodeManager {
    /// Handle to the Veilid API.
    api: VeilidAPI,
    /// Current node state, shared so the update callback can mutate it.
    state: Arc<Mutex<NodeState>>,
}

impl NodeManager {
    /// Creates a new `NodeManager` wrapping the given Veilid API.
    pub fn new(api: VeilidAPI) -> Self {
        Self {
            api,
            state: Arc::new(Mutex::new(NodeState::Detached)),
        }
    }

    /// Returns a clone of the shared state handle, suitable for passing
    /// to the update callback via `handle_update`.
    pub fn state_handle(&self) -> Arc<Mutex<NodeState>> {
        Arc::clone(&self.state)
    }

    /// Returns the current node state.
    pub fn current_state(&self) -> NodeState {
        self.state.lock().unwrap().clone()
    }

    /// Returns a reference to the Veilid API.
    pub fn api(&self) -> &VeilidAPI {
        &self.api
    }
}

/// Attach the node to the Veilid network.
pub async fn start(api: &VeilidAPI) -> Result<()> {
    tracing::info!("Attaching Veilid node to network");
    api.attach().await?;
    Ok(())
}

/// Detach from the network and shut down the Veilid API.
pub async fn stop(api: VeilidAPI) -> Result<()> {
    tracing::info!("Detaching and shutting down Veilid node");
    api.detach().await?;
    api.shutdown().await;
    Ok(())
}

/// Process a `VeilidUpdate` and update the shared node state accordingly.
///
/// This should be called from the Veilid update callback. It matches on
/// attachment-related updates and translates them into `NodeState` values.
pub fn handle_update(update: VeilidUpdate, state: Arc<Mutex<NodeState>>) {
    if let VeilidUpdate::Attachment(box_attachment) = update {
        let attachment: VeilidStateAttachment = *box_attachment;
        let new_state = match attachment.state {
            AttachmentState::Detached => NodeState::Detached,
            AttachmentState::Attaching => NodeState::Attaching,
            AttachmentState::AttachedWeak | AttachmentState::AttachedGood | AttachmentState::AttachedStrong => {
                NodeState::Attached
            }
            AttachmentState::FullyAttached => NodeState::FullyAttached,
            AttachmentState::Detaching => NodeState::Detaching,
            AttachmentState::OverAttached => NodeState::FullyAttached,
        };
        tracing::debug!("Node state changed to {:?}", new_state);
        *state.lock().unwrap() = new_state;
    }
}

/// Wait until the node reaches at least `Attached` state, or until timeout.
///
/// Polls the Veilid API's attachment state at short intervals. Returns an
/// error if the timeout is exceeded before the node attaches.
pub async fn wait_for_attach(api: &VeilidAPI, timeout: Duration) -> Result<()> {
    tracing::info!("Waiting for node to attach (timeout={:?})", timeout);
    let start = tokio::time::Instant::now();
    let poll_interval = Duration::from_millis(250);

    loop {
        let state = api.get_state().await?;
        match state.attachment.state {
            AttachmentState::FullyAttached | AttachmentState::OverAttached => {
                tracing::info!("Node is fully attached");
                return Ok(());
            }
            AttachmentState::AttachedWeak
            | AttachmentState::AttachedGood
            | AttachmentState::AttachedStrong => {
                tracing::info!("Node is attached (state={:?})", state.attachment.state);
                return Ok(());
            }
            _ => {}
        }

        if start.elapsed() >= timeout {
            return Err(crate::SpheresError::Generic(format!(
                "Timed out waiting for node to attach after {:?}",
                timeout
            )));
        }

        tokio::time::sleep(poll_interval).await;
    }
}
