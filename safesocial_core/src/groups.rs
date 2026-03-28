//! Group chat management via Veilid DHT records.
//!
//! A group is a DHT record with subkeys for metadata, members, and per-member
//! message slots. The group creator is automatically assigned the Admin role.

use std::str::FromStr;
use serde::{Deserialize, Serialize};
use veilid_core::*;

use crate::schema::{self, GROUP_SUBKEY_MEMBERS, GROUP_SUBKEY_META};
use crate::Result;

/// Metadata describing a group.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GroupMeta {
    /// The group's human-readable name.
    pub name: String,
    /// A description of the group's purpose.
    pub description: String,
    /// Public key of the user who created the group.
    pub created_by: String,
    /// Unix timestamp of group creation.
    pub created_at: i64,
    /// Optional reference to an avatar in the block store.
    pub avatar_ref: Option<String>,
}

/// A member of a group.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GroupMember {
    /// The member's public key.
    pub public_key: String,
    /// The member's display name.
    pub display_name: String,
    /// The member's role within the group.
    pub role: GroupRole,
    /// Unix timestamp when the member joined.
    pub joined_at: i64,
}

/// Role assigned to a group member.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum GroupRole {
    /// Full control: can add/remove members, edit group metadata, etc.
    Admin,
    /// Regular member: can read and send messages.
    Member,
}

/// Create a new group, writing metadata and the initial member list.
///
/// The `creator` is automatically included in the member list. Returns
/// the DHT key for the group record.
pub async fn create_group(
    api: &VeilidAPI,
    rc: &RoutingContext,
    meta: &GroupMeta,
    creator: &GroupMember,
) -> Result<RecordKey> {
    tracing::info!("Creating group '{}'", meta.name);

    let creator_key = PublicKey::from_str(&creator.public_key)
        .map_err(|e| crate::SpheresError::CryptoError(e.to_string()))?;
    let member_id = api.generate_member_id(&creator_key)?;

    let kind = VALID_CRYPTO_KINDS[0];
    let dht_schema = schema::group_schema(vec![(member_id, 256u16)])?;
    let record = rc.create_dht_record(kind, dht_schema, None).await?;
    let key = record.key().clone();

    // Write group metadata to subkey 0
    let meta_serialized = schema::serialize(meta)?;
    rc.set_dht_value(key.clone(), GROUP_SUBKEY_META, meta_serialized, None)
        .await?;

    // Write initial member list (just the creator) to subkey 1
    let members = vec![creator.clone()];
    let members_serialized = schema::serialize(&members)?;
    rc.set_dht_value(key.clone(), GROUP_SUBKEY_MEMBERS, members_serialized, None)
        .await?;

    rc.close_dht_record(key.clone()).await?;
    tracing::info!("Group created with key {:?}", key);

    Ok(key)
}

/// Retrieve the metadata for a group.
pub async fn get_group_meta(
    rc: &RoutingContext,
    key: RecordKey,
) -> Result<Option<GroupMeta>> {
    tracing::debug!("Getting group meta for {:?}", key);

    let _record = rc.open_dht_record(key.clone(), None).await?;
    let value = rc
        .get_dht_value(key.clone(), GROUP_SUBKEY_META, false)
        .await?;
    rc.close_dht_record(key).await?;

    match value {
        Some(value_data) => {
            let meta: GroupMeta = schema::deserialize(value_data.data())?;
            Ok(Some(meta))
        }
        None => Ok(None),
    }
}

/// Retrieve the current member list for a group.
pub async fn get_group_members(
    rc: &RoutingContext,
    key: RecordKey,
) -> Result<Vec<GroupMember>> {
    tracing::debug!("Getting group members for {:?}", key);

    let _record = rc.open_dht_record(key.clone(), None).await?;
    let value = rc
        .get_dht_value(key.clone(), GROUP_SUBKEY_MEMBERS, false)
        .await?;
    rc.close_dht_record(key).await?;

    match value {
        Some(value_data) => {
            let members: Vec<GroupMember> = schema::deserialize(value_data.data())?;
            Ok(members)
        }
        None => Ok(Vec::new()),
    }
}

/// Add a new member to a group.
///
/// Reads the current member list, appends the new member, and writes it back.
/// The `writer` keypair must have write access to the record.
pub async fn add_member(
    rc: &RoutingContext,
    key: RecordKey,
    writer: KeyPair,
    member: GroupMember,
) -> Result<()> {
    tracing::info!("Adding member {} to group {:?}", member.display_name, key);

    let _record = rc
        .open_dht_record(key.clone(), Some(writer))
        .await?;

    // Read current members
    let mut members: Vec<GroupMember> = match rc
        .get_dht_value(key.clone(), GROUP_SUBKEY_MEMBERS, false)
        .await?
    {
        Some(value_data) => schema::deserialize(value_data.data())?,
        None => Vec::new(),
    };

    members.push(member);

    let serialized = schema::serialize(&members)?;
    rc.set_dht_value(key.clone(), GROUP_SUBKEY_MEMBERS, serialized, None)
        .await?;
    rc.close_dht_record(key).await?;

    Ok(())
}

/// Remove a member from a group by their public key.
///
/// The `writer` keypair must have write access to the record.
pub async fn remove_member(
    rc: &RoutingContext,
    key: RecordKey,
    writer: KeyPair,
    public_key: &str,
) -> Result<()> {
    tracing::info!("Removing member {} from group {:?}", public_key, key);

    let _record = rc
        .open_dht_record(key.clone(), Some(writer))
        .await?;

    // Read current members
    let mut members: Vec<GroupMember> = match rc
        .get_dht_value(key.clone(), GROUP_SUBKEY_MEMBERS, false)
        .await?
    {
        Some(value_data) => schema::deserialize(value_data.data())?,
        None => Vec::new(),
    };

    members.retain(|m| m.public_key != public_key);

    let serialized = schema::serialize(&members)?;
    rc.set_dht_value(key.clone(), GROUP_SUBKEY_MEMBERS, serialized, None)
        .await?;
    rc.close_dht_record(key).await?;

    Ok(())
}

/// Send a message to a group's DHT record.
///
/// Group messages are written to member-specific subkeys starting at
/// subkey index 2 (after meta and members). Each member gets a range
/// of subkeys based on their index in the member list.
pub async fn send_group_message(
    rc: &RoutingContext,
    group_key: RecordKey,
    writer: KeyPair,
    msg: &crate::messaging::DirectMessage,
) -> Result<()> {
    tracing::info!("Sending group message {} to {:?}", msg.id, group_key);

    let _record = rc
        .open_dht_record(group_key.clone(), Some(writer))
        .await?;

    // Read the member list to find the sender's subkey range
    let members: Vec<GroupMember> = match rc
        .get_dht_value(group_key.clone(), GROUP_SUBKEY_MEMBERS, false)
        .await?
    {
        Some(value_data) => schema::deserialize(value_data.data())?,
        None => Vec::new(),
    };

    // Find the sender's index in the member list
    let sender_index = members
        .iter()
        .position(|m| m.public_key == msg.sender)
        .ok_or_else(|| {
            crate::SpheresError::Generic(format!(
                "Sender {} is not a member of group {:?}",
                msg.sender, group_key
            ))
        })?;

    // Each member's message area starts at subkey (2 + sender_index)
    // For now, we use a simple scheme: one subkey per member for latest message.
    // A more sophisticated version would maintain per-member counters.
    let subkey = (2 + sender_index) as u32;

    let serialized = schema::serialize(msg)?;
    rc.set_dht_value(group_key.clone(), subkey, serialized, None)
        .await?;
    rc.close_dht_record(group_key).await?;

    tracing::debug!(
        "Group message written to subkey {} (member index {})",
        subkey,
        sender_index
    );

    Ok(())
}
