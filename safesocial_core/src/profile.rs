//! DHT-backed user profile CRUD operations.
//!
//! Each user's profile is a Veilid DHT record with three subkeys:
//! - Subkey 0: serialized `ProfileData` (name, bio, avatar ref, timestamp)
//! - Subkey 1: avatar block-store reference
//! - Subkey 2: online/offline status flag

use serde::{Deserialize, Serialize};
use veilid_core::*;

use crate::schema::{self, PROFILE_SUBKEY_INFO, PROFILE_SUBKEY_STATUS};
use crate::Result;

/// Core profile information stored in the DHT.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProfileData {
    /// The user's chosen display name.
    pub display_name: String,
    /// A short biography or status message.
    pub bio: String,
    /// Optional reference to an avatar in the block store.
    pub avatar_ref: Option<String>,
    /// Unix timestamp of the last profile update.
    pub updated_at: i64,
}

/// Create a new profile DHT record and write the initial data.
///
/// Returns the `RecordKey` that other users can use to look up this profile.
pub async fn create_profile(rc: &RoutingContext, data: &ProfileData) -> Result<RecordKey> {
    tracing::info!("Creating profile DHT record");

    let kind = VALID_CRYPTO_KINDS[0];
    let dht_schema = schema::profile_schema()?;
    let record = rc.create_dht_record(kind, dht_schema, None).await?;
    let key = record.key().clone();

    let serialized = schema::serialize(data)?;
    rc.set_dht_value(key.clone(), PROFILE_SUBKEY_INFO, serialized, None)
        .await?;

    rc.close_dht_record(key.clone()).await?;
    tracing::info!("Profile created with key {:?}", key);
    Ok(key)
}

/// Update an existing profile record with new data.
///
/// The caller must own the record (have the writer keypair in scope).
pub async fn update_profile(
    rc: &RoutingContext,
    key: RecordKey,
    data: &ProfileData,
) -> Result<()> {
    tracing::debug!("Updating profile {:?}", key);

    let _record = rc.open_dht_record(key.clone(), None).await?;
    let serialized = schema::serialize(data)?;
    rc.set_dht_value(key.clone(), PROFILE_SUBKEY_INFO, serialized, None)
        .await?;
    rc.close_dht_record(key).await?;

    Ok(())
}

/// Retrieve the profile data for a given DHT key.
///
/// Returns `None` if the record exists but the info subkey has not been written.
pub async fn get_profile(rc: &RoutingContext, key: RecordKey) -> Result<Option<ProfileData>> {
    tracing::debug!("Getting profile {:?}", key);

    let _record = rc.open_dht_record(key.clone(), None).await?;
    let value = rc.get_dht_value(key.clone(), PROFILE_SUBKEY_INFO, false).await?;
    rc.close_dht_record(key).await?;

    match value {
        Some(value_data) => {
            let profile: ProfileData = schema::deserialize(value_data.data())?;
            Ok(Some(profile))
        }
        None => Ok(None),
    }
}

/// Set the online/offline status flag on a profile.
///
/// Writes a JSON boolean to subkey 2 of the profile record.
pub async fn set_online_status(
    rc: &RoutingContext,
    key: RecordKey,
    online: bool,
) -> Result<()> {
    tracing::debug!("Setting online status for {:?} to {}", key, online);

    let _record = rc.open_dht_record(key.clone(), None).await?;
    let serialized = schema::serialize(&online)?;
    rc.set_dht_value(key.clone(), PROFILE_SUBKEY_STATUS, serialized, None)
        .await?;
    rc.close_dht_record(key).await?;

    Ok(())
}
