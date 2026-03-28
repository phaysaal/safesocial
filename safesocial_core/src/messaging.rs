//! Direct messaging via Veilid DHT records.
//!
//! Each conversation is a DHT record shared between participants. Subkey 0
//! holds a message counter (the index of the next subkey to write to), and
//! subsequent subkeys hold individual messages in chronological order.
//!
//! Messages are also cached locally in the TableStore for offline access.

use serde::{Deserialize, Serialize};
use veilid_core::*;

use crate::schema::{self, MESSAGE_SUBKEY_LATEST};
use crate::ratchet::SecureSessionManager;
use crate::Result;

/// A single direct message between two users.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DirectMessage {
    /// Unique message identifier (UUID v4).
    pub id: String,
    /// Public key of the sender.
    pub sender: String,
    /// Public key of the recipient.
    pub recipient: String,
    /// The message text content (plaintext - only for local cache).
    #[serde(skip_serializing_if = "String::is_empty")]
    pub content: String,
    /// Encrypted message payload (for DHT storage).
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub encrypted_payload: Vec<u8>,
    /// Unix timestamp when the message was created.
    pub timestamp: i64,
    /// Whether this message has been confirmed delivered.
    pub delivered: bool,
}

/// Local message storage backed by the Veilid TableStore.
pub struct MessageStore {
    /// Handle to the Veilid API for TableStore access.
    api: VeilidAPI,
}

impl MessageStore {
    /// Create a new `MessageStore` with the given Veilid API handle.
    pub fn new(api: VeilidAPI) -> Self {
        Self { api }
    }

    /// Cache a message locally for offline access.
    pub async fn cache(&self, conversation_id: &str, msg: &DirectMessage) -> Result<()> {
        cache_message(&self.api, conversation_id, msg).await
    }

    /// Load all cached messages for a conversation.
    pub async fn load_cached(&self, conversation_id: &str) -> Result<Vec<DirectMessage>> {
        load_cached_messages(&self.api, conversation_id).await
    }
}

/// Counter metadata stored at subkey 0 of every conversation record.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct ConversationMeta {
    /// The next subkey index to write a message to.
    next_subkey: u32,
}

/// Send a message to a conversation's DHT record.
///
/// Reads the current counter from subkey 0, writes the message to the next
/// available subkey, then increments and writes back the counter.
pub async fn send_message(
    rc: &RoutingContext,
    session_manager: &mut SecureSessionManager,
    conversation_key: RecordKey,
    writer: KeyPair,
    mut msg: DirectMessage,
) -> Result<()> {
    tracing::info!("Sending message {} to conversation {:?}", msg.id, conversation_key);

    // 1. Encrypt the payload using the ratchet session
    let plaintext = msg.content.as_bytes();
    let encrypted = session_manager.encrypt_ratcheted(&msg.recipient, plaintext)?;
    
    // 2. Prepare the message for the DHT (clear content, set encrypted payload)
    msg.encrypted_payload = encrypted;
    msg.content = String::new(); // Don't store plaintext on DHT

    let _record = rc
        .open_dht_record(conversation_key.clone(), Some(writer))
        .await?;

    // Read the current counter from subkey 0
    let meta = match rc
        .get_dht_value(conversation_key.clone(), MESSAGE_SUBKEY_LATEST, false)
        .await?
    {
        Some(value_data) => schema::deserialize::<ConversationMeta>(value_data.data())?,
        None => ConversationMeta { next_subkey: 1 }, // Start at 1 since 0 is the counter
    };

    let msg_subkey = meta.next_subkey;

    // Write the message to the next available subkey
    let serialized = schema::serialize(&msg)?;
    rc.set_dht_value(conversation_key.clone(), msg_subkey, serialized, None)
        .await?;

    // Update the counter
    let new_meta = ConversationMeta {
        next_subkey: msg_subkey + 1,
    };
    let meta_serialized = schema::serialize(&new_meta)?;
    rc.set_dht_value(conversation_key.clone(), MESSAGE_SUBKEY_LATEST, meta_serialized, None)
        .await?;

    rc.close_dht_record(conversation_key).await?;
    tracing::debug!("Message written to subkey {}", msg_subkey);

    Ok(())
}

/// Read a range of messages from a conversation's DHT record.
///
/// Reads subkeys `start_subkey` through `start_subkey + count - 1`. Missing
/// or empty subkeys are silently skipped.
pub async fn get_messages(
    rc: &RoutingContext,
    session_manager: &mut SecureSessionManager,
    conversation_key: RecordKey,
    start_subkey: u32,
    count: u32,
) -> Result<Vec<DirectMessage>> {
    tracing::debug!(
        "Reading messages from {:?} subkeys {}..{}",
        conversation_key,
        start_subkey,
        start_subkey + count
    );

    let _record = rc
        .open_dht_record(conversation_key.clone(), None)
        .await?;

    let mut messages = Vec::new();
    for subkey in start_subkey..(start_subkey + count) {
        match rc
            .get_dht_value(conversation_key.clone(), subkey, false)
            .await?
        {
            Some(value_data) => {
                match schema::deserialize::<DirectMessage>(value_data.data()) {
                    Ok(mut msg) => {
                        // Decrypt the payload if it exists
                        if !msg.encrypted_payload.is_empty() {
                            match session_manager.decrypt_ratcheted(&msg.sender, &msg.encrypted_payload) {
                                Ok(plaintext) => {
                                    msg.content = String::from_utf8_lossy(&plaintext).into_owned();
                                    msg.encrypted_payload = Vec::new(); // Clear after decryption
                                    messages.push(msg);
                                }
                                Err(e) => {
                                    tracing::error!("Failed to decrypt message {}: {}", msg.id, e);
                                }
                            }
                        } else {
                            messages.push(msg);
                        }
                    },
                    Err(e) => {
                        tracing::warn!("Failed to deserialize message at subkey {}: {}", subkey, e);
                    }
                }
            }
            None => {
                tracing::debug!("No data at subkey {}", subkey);
            }
        }
    }

    rc.close_dht_record(conversation_key).await?;
    tracing::debug!("Read {} messages", messages.len());

    Ok(messages)
}

/// Create a new two-party conversation DHT record.
///
/// Returns the `RecordKey` that both parties use to read and write messages.
pub async fn create_conversation(
    api: &VeilidAPI,
    rc: &RoutingContext,
    contact_public_key: &PublicKey,
) -> Result<RecordKey> {
    tracing::info!("Creating new conversation record for contact {}", contact_public_key);

    let member_id = api.generate_member_id(contact_public_key)?;
    
    let kind = VALID_CRYPTO_KINDS[0];
    let dht_schema = schema::conversation_schema(256, member_id, 256)?;
    let record = rc.create_dht_record(kind, dht_schema, None).await?;
    let key = record.key().clone();

    // Initialize the counter at subkey 0
    let meta = ConversationMeta { next_subkey: 1 };
    let serialized = schema::serialize(&meta)?;
    rc.set_dht_value(key.clone(), MESSAGE_SUBKEY_LATEST, serialized, None)
        .await?;

    rc.close_dht_record(key.clone()).await?;
    tracing::info!("Conversation created with key {:?}", key);

    Ok(key)
}

/// Cache a message in the local TableStore for offline access.
///
/// Messages are stored as a JSON array keyed by the conversation ID.
pub async fn cache_message(
    api: &VeilidAPI,
    conversation_id: &str,
    msg: &DirectMessage,
) -> Result<()> {
    tracing::debug!("Caching message {} for conversation {}", msg.id, conversation_id);

    let ts = api.table_store()?;
    let db = ts.open("message_cache", 1).await?;
    let table_key = format!("conv_{}", conversation_id);

    // Load existing cached messages
    let mut messages: Vec<DirectMessage> = match db.load(0, table_key.as_bytes()).await? {
        Some(data) => schema::deserialize(&data).unwrap_or_default(),
        None => Vec::new(),
    };

    messages.push(msg.clone());

    let serialized = schema::serialize(&messages)?;
    db.store(0, table_key.as_bytes(), &serialized).await?;

    Ok(())
}

/// Load all cached messages for a conversation from the local TableStore.
pub async fn load_cached_messages(
    api: &VeilidAPI,
    conversation_id: &str,
) -> Result<Vec<DirectMessage>> {
    tracing::debug!("Loading cached messages for conversation {}", conversation_id);

    let ts = api.table_store()?;
    let db = ts.open("message_cache", 1).await?;
    let table_key = format!("conv_{}", conversation_id);

    match db.load(0, table_key.as_bytes()).await? {
        Some(data) => {
            let messages: Vec<DirectMessage> = schema::deserialize(&data)?;
            tracing::debug!("Loaded {} cached messages", messages.len());
            Ok(messages)
        }
        None => {
            tracing::debug!("No cached messages found");
            Ok(Vec::new())
        }
    }
}

/// Generate a new unique message ID.
pub fn new_message_id() -> String {
    uuid::Uuid::new_v4().to_string()
}
