//! Media handling with placeholder Block Store implementation.
//!
//! The Veilid Block Store API is still being stabilized, so these functions
//! use the TableStore as a temporary backend. Once the Block Store API is
//! finalized, this module will be updated to use it directly for content-
//! addressed, encrypted media storage.

use serde::{Deserialize, Serialize};
use veilid_core::*;

use crate::schema;
use crate::Result;

/// Reference to a stored media object.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaRef {
    /// Content-addressed block identifier (hash of the data).
    pub block_id: String,
    /// MIME type of the media (e.g. "image/png", "video/mp4").
    pub mime_type: String,
    /// Size of the media data in bytes.
    pub size: u64,
    /// Optional reference to a thumbnail block.
    pub thumbnail_id: Option<String>,
    /// Whether the media blob is encrypted at rest.
    pub encrypted: bool,
}

const MEDIA_TABLE: &str = "media_store";

/// Compute a hex-encoded SHA-256-like hash for use as a block ID.
///
/// This is a simple placeholder hash using Veilid's crypto. In production
/// this would use the Block Store's content-addressing scheme.
fn compute_block_id(data: &[u8]) -> String {
    // Use a simple hash: take the first 32 bytes of a SHA-256-style digest.
    // For the placeholder we use a basic approach with std hashing.
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};

    let mut hasher = DefaultHasher::new();
    data.hash(&mut hasher);
    let hash_a = hasher.finish();

    // Hash again with a different seed for more bits
    let mut hasher2 = DefaultHasher::new();
    hash_a.hash(&mut hasher2);
    data.len().hash(&mut hasher2);
    let hash_b = hasher2.finish();

    format!("{:016x}{:016x}", hash_a, hash_b)
}

/// Store media data and return a `MediaRef`.
///
/// **NOTE:** The Veilid Block Store API is still being stabilized. This
/// implementation uses the TableStore as a temporary backend. Media is
/// stored under a key prefixed with `"media_"` followed by the content hash.
pub async fn store_media(
    api: &VeilidAPI,
    data: &[u8],
    mime_type: &str,
) -> Result<MediaRef> {
    tracing::info!("Storing media ({} bytes, type={})", data.len(), mime_type);

    let block_id = compute_block_id(data);
    let table_key = format!("media_{}", block_id);

    let ts = api.table_store()?;
    let db = ts.open(MEDIA_TABLE, 1).await?;
    db.store(0, table_key.as_bytes(), data).await?;

    let media_ref = MediaRef {
        block_id,
        mime_type: mime_type.to_string(),
        size: data.len() as u64,
        thumbnail_id: None,
        encrypted: false, // Placeholder: encryption not yet implemented
    };

    // Also store the MediaRef metadata
    let meta_key = format!("meta_{}", media_ref.block_id);
    let meta_serialized = schema::serialize(&media_ref)?;
    db.store(0, meta_key.as_bytes(), &meta_serialized).await?;

    tracing::info!("Media stored with block_id={}", media_ref.block_id);
    Ok(media_ref)
}

/// Retrieve media data by its `MediaRef`.
///
/// **NOTE:** Temporary TableStore-based implementation. See `store_media`.
pub async fn retrieve_media(
    api: &VeilidAPI,
    media_ref: &MediaRef,
) -> Result<Vec<u8>> {
    tracing::debug!("Retrieving media block_id={}", media_ref.block_id);

    let table_key = format!("media_{}", media_ref.block_id);

    let ts = api.table_store()?;
    let db = ts.open(MEDIA_TABLE, 1).await?;

    match db.load(0, table_key.as_bytes()).await? {
        Some(data) => {
            tracing::debug!("Retrieved {} bytes", data.len());
            Ok(data)
        }
        None => Err(crate::SafeSocialError::RecordNotFound(format!(
            "Media not found: {}",
            media_ref.block_id
        ))),
    }
}

/// Store a thumbnail image and return its block ID.
///
/// **NOTE:** Temporary TableStore-based implementation. See `store_media`.
pub async fn store_thumbnail(api: &VeilidAPI, data: &[u8]) -> Result<String> {
    tracing::debug!("Storing thumbnail ({} bytes)", data.len());

    let block_id = compute_block_id(data);
    let table_key = format!("media_thumb_{}", block_id);

    let ts = api.table_store()?;
    let db = ts.open(MEDIA_TABLE, 1).await?;
    db.store(0, table_key.as_bytes(), data).await?;

    tracing::debug!("Thumbnail stored with block_id={}", block_id);
    Ok(block_id)
}

/// Delete media data associated with a `MediaRef`.
///
/// **NOTE:** Temporary TableStore-based implementation. See `store_media`.
pub async fn delete_media(api: &VeilidAPI, media_ref: &MediaRef) -> Result<()> {
    tracing::info!("Deleting media block_id={}", media_ref.block_id);

    let table_key = format!("media_{}", media_ref.block_id);
    let meta_key = format!("meta_{}", media_ref.block_id);

    let ts = api.table_store()?;
    let db = ts.open(MEDIA_TABLE, 1).await?;
    db.delete(0, table_key.as_bytes()).await?;
    db.delete(0, meta_key.as_bytes()).await?;

    // Also delete thumbnail if it exists
    if let Some(ref thumb_id) = media_ref.thumbnail_id {
        let thumb_key = format!("media_thumb_{}", thumb_id);
        db.delete(0, thumb_key.as_bytes()).await?;
    }

    tracing::info!("Media deleted: {}", media_ref.block_id);
    Ok(())
}
