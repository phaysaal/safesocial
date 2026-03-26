//! DHT record schemas and serialization helpers.
//!
//! Defines the subkey layout for each record type (profiles, conversations,
//! posts, groups) and provides convenience functions for creating the
//! corresponding `DHTSchema` values and for serializing/deserializing
//! data stored in DHT subkeys.

use serde::de::DeserializeOwned;
use serde::Serialize;
use veilid_core::*;

// ---------------------------------------------------------------------------
// Profile subkey indices
// ---------------------------------------------------------------------------

/// Profile subkey: display name, bio, and metadata.
pub const PROFILE_SUBKEY_INFO: u32 = 0;
/// Profile subkey: avatar block-store reference.
pub const PROFILE_SUBKEY_AVATAR: u32 = 1;
/// Profile subkey: online/offline status flag.
pub const PROFILE_SUBKEY_STATUS: u32 = 2;

// ---------------------------------------------------------------------------
// Message subkey indices
// ---------------------------------------------------------------------------

/// Conversation subkey: latest message counter / metadata.
pub const MESSAGE_SUBKEY_LATEST: u32 = 0;

// ---------------------------------------------------------------------------
// Post subkey indices
// ---------------------------------------------------------------------------

/// Post subkey: the post content itself.
pub const POST_SUBKEY_CONTENT: u32 = 0;
/// Post subkey: list of reactions.
pub const POST_SUBKEY_REACTIONS: u32 = 1;

// ---------------------------------------------------------------------------
// Group subkey indices
// ---------------------------------------------------------------------------

/// Group subkey: group metadata (name, description, creator, etc.).
pub const GROUP_SUBKEY_META: u32 = 0;
/// Group subkey: member list.
pub const GROUP_SUBKEY_MEMBERS: u32 = 1;

// ---------------------------------------------------------------------------
// Schema creation
// ---------------------------------------------------------------------------

/// Creates a DHT schema for a user profile (3 subkeys: info, avatar, status).
pub fn profile_schema() -> VeilidAPIResult<DHTSchema> {
    DHTSchema::dflt(3)
}

/// Creates a DHT schema for a conversation between `member_count` participants.
///
/// Each member gets 256 subkeys for their message history, providing ample
/// room for scrollback without record rotation.
pub fn conversation_schema(member_count: u16) -> VeilidAPIResult<DHTSchema> {
    DHTSchema::dflt(member_count * 256)
}

/// Creates a DHT schema for a single post (2 subkeys: content, reactions).
pub fn post_schema() -> VeilidAPIResult<DHTSchema> {
    DHTSchema::dflt(2)
}

/// Creates a DHT schema for a group chat.
///
/// Reserves `max_members + 2` subkeys: one for metadata, one for the member
/// list, and one per member for writing messages.
pub fn group_schema(max_members: u16) -> VeilidAPIResult<DHTSchema> {
    DHTSchema::dflt(max_members + 2)
}

// ---------------------------------------------------------------------------
// Serialization helpers
// ---------------------------------------------------------------------------

/// Serialize a value to a JSON byte vector for DHT storage.
pub fn serialize<T: Serialize>(value: &T) -> crate::Result<Vec<u8>> {
    serde_json::to_vec(value).map_err(crate::SpheresError::Serialization)
}

/// Deserialize a value from a JSON byte slice read from the DHT.
pub fn deserialize<T: DeserializeOwned>(data: &[u8]) -> crate::Result<T> {
    serde_json::from_slice(data).map_err(crate::SpheresError::Serialization)
}
