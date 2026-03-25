//! Post/feed system backed by Veilid DHT and local TableStore.
//!
//! Each post is its own DHT record with two subkeys: one for the post content
//! and one for reactions. Published post keys are tracked locally in the
//! TableStore so contacts can discover and fetch them.

use serde::{Deserialize, Serialize};
use veilid_core::*;

use crate::schema::{self, POST_SUBKEY_CONTENT, POST_SUBKEY_REACTIONS};
use crate::Result;

/// A single post in the user's feed.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Post {
    /// Unique post identifier (UUID v4).
    pub id: String,
    /// Public key of the post author.
    pub author: String,
    /// The post's text content.
    pub content: String,
    /// References to media attachments (block store IDs).
    pub media_refs: Vec<String>,
    /// Unix timestamp when the post was created.
    pub created_at: i64,
    /// Unix timestamp of the last edit, if any.
    pub edited_at: Option<i64>,
}

/// A reaction on a post.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Reaction {
    /// Public key of the user who reacted.
    pub reactor: String,
    /// The emoji used as the reaction.
    pub emoji: String,
    /// Unix timestamp of the reaction.
    pub timestamp: i64,
}

/// Create a new post as a DHT record.
///
/// Writes the post content to subkey 0 and returns the DHT key.
pub async fn create_post(rc: &RoutingContext, post: &Post) -> Result<RecordKey> {
    tracing::info!("Creating post {} by {}", post.id, post.author);

    let kind = VALID_CRYPTO_KINDS[0];
    let dht_schema = schema::post_schema()?;
    let record = rc.create_dht_record(kind, dht_schema, None).await?;
    let key = record.key().clone();

    let serialized = schema::serialize(post)?;
    rc.set_dht_value(key.clone(), POST_SUBKEY_CONTENT, serialized, None)
        .await?;

    rc.close_dht_record(key.clone()).await?;
    tracing::info!("Post created with key {:?}", key);

    Ok(key)
}

/// Retrieve a post from its DHT key.
///
/// Returns `None` if the record exists but the content subkey is empty.
pub async fn get_post(rc: &RoutingContext, key: RecordKey) -> Result<Option<Post>> {
    tracing::debug!("Getting post {:?}", key);

    let _record = rc.open_dht_record(key.clone(), None).await?;
    let value = rc
        .get_dht_value(key.clone(), POST_SUBKEY_CONTENT, false)
        .await?;
    rc.close_dht_record(key).await?;

    match value {
        Some(value_data) => {
            let post: Post = schema::deserialize(value_data.data())?;
            Ok(Some(post))
        }
        None => Ok(None),
    }
}

/// Add a reaction to a post.
///
/// Reads the existing reactions from subkey 1, appends the new reaction,
/// and writes the updated list back.
pub async fn add_reaction(
    rc: &RoutingContext,
    post_key: RecordKey,
    reaction: &Reaction,
) -> Result<()> {
    tracing::debug!(
        "Adding reaction {} from {} to post {:?}",
        reaction.emoji,
        reaction.reactor,
        post_key
    );

    let _record = rc.open_dht_record(post_key.clone(), None).await?;

    // Read existing reactions
    let mut reactions: Vec<Reaction> = match rc
        .get_dht_value(post_key.clone(), POST_SUBKEY_REACTIONS, false)
        .await?
    {
        Some(value_data) => schema::deserialize(value_data.data()).unwrap_or_default(),
        None => Vec::new(),
    };

    reactions.push(reaction.clone());

    let serialized = schema::serialize(&reactions)?;
    rc.set_dht_value(post_key.clone(), POST_SUBKEY_REACTIONS, serialized, None)
        .await?;
    rc.close_dht_record(post_key).await?;

    Ok(())
}

/// Get all reactions on a post.
pub async fn get_reactions(
    rc: &RoutingContext,
    post_key: RecordKey,
) -> Result<Vec<Reaction>> {
    tracing::debug!("Getting reactions for post {:?}", post_key);

    let _record = rc.open_dht_record(post_key.clone(), None).await?;
    let value = rc
        .get_dht_value(post_key.clone(), POST_SUBKEY_REACTIONS, false)
        .await?;
    rc.close_dht_record(post_key).await?;

    match value {
        Some(value_data) => {
            let reactions: Vec<Reaction> = schema::deserialize(value_data.data())?;
            Ok(reactions)
        }
        None => Ok(Vec::new()),
    }
}

/// Track a published post key in the local TableStore.
///
/// This allows the user's contacts to discover the post when they
/// poll for new content.
pub async fn publish_to_feed(api: &VeilidAPI, post_key: RecordKey) -> Result<()> {
    tracing::info!("Publishing post {:?} to local feed index", post_key);

    let ts = api.table_store()?;
    let db = ts.open("feed_published", 1).await?;

    // Load existing keys
    let mut keys: Vec<RecordKey> = match db.load(0, b"post_keys").await? {
        Some(data) => schema::deserialize(&data).unwrap_or_default(),
        None => Vec::new(),
    };

    keys.push(post_key);

    let serialized = schema::serialize(&keys)?;
    db.store(0, b"post_keys", &serialized).await?;

    Ok(())
}

/// Load all published post keys from the local TableStore.
pub async fn get_feed_keys(api: &VeilidAPI) -> Result<Vec<RecordKey>> {
    tracing::debug!("Loading published feed keys");

    let ts = api.table_store()?;
    let db = ts.open("feed_published", 1).await?;

    match db.load(0, b"post_keys").await? {
        Some(data) => {
            let keys: Vec<RecordKey> = schema::deserialize(&data)?;
            tracing::debug!("Loaded {} feed keys", keys.len());
            Ok(keys)
        }
        None => {
            tracing::debug!("No feed keys found");
            Ok(Vec::new())
        }
    }
}
