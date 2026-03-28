//! Content encryption and privacy protocol for Spheres.
//!
//! Implements per-content encryption with four privacy levels:
//! - `OnlyMe`: encrypted with device key, only creator can decrypt
//! - `Individual`: encrypted for creator + one recipient via x25519 DH
//! - `Group`: encrypted with group symmetric key
//! - `Public`: no encryption (plaintext + signature)
//!
//! Every content item gets a unique random content key. The content key is
//! then "wrapped" (encrypted) separately for each authorized recipient.

use std::str::FromStr;
use serde::{Deserialize, Serialize};
use veilid_core::*;

use crate::Result;

/// Privacy level for a piece of content.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum ContentPrivacy {
    /// Only the creator can view this content.
    OnlyMe,
    /// Shared with exactly one other person.
    Individual {
        recipient: String, // base64 public key
    },
    /// Shared with a group of people.
    Group {
        group_id: String,
        epoch: u32,
    },
    /// Visible to anyone — no encryption.
    Public,
}

/// A wrapped content key for one recipient.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WrappedKey {
    /// Recipient identifier: base64 public key or "group:<id>"
    pub recipient: String,
    /// The content key, encrypted for this recipient.
    pub wrapped_content_key: Vec<u8>,
    /// Nonce used for the key wrapping encryption.
    pub key_nonce: Vec<u8>,
    /// Key wrapping method used.
    pub method: String,
}

/// The access control envelope stored on DHT alongside encrypted content.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContentEnvelope {
    pub version: u32,
    /// Creator's public key (base64).
    pub creator: String,
    /// Privacy level.
    pub privacy: ContentPrivacy,
    /// BLAKE3 hash of the encrypted content blob.
    pub content_hash: String,
    /// Nonce used for content encryption.
    pub content_nonce: Vec<u8>,
    /// MIME type of the original content.
    pub mime_type: String,
    /// Size of the original plaintext in bytes.
    pub content_size: u64,
    /// Unix timestamp of creation.
    pub created_at: i64,
    /// Wrapped content keys for each authorized recipient.
    pub wrapped_keys: Vec<WrappedKey>,
    /// Ed25519 signature over the envelope (excluding this field).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature: Option<Vec<u8>>,
}

/// Result of encrypting content.
pub struct EncryptedContent {
    /// The encrypted content bytes (to store in BlockStore).
    pub encrypted_bytes: Vec<u8>,
    /// The access control envelope (to store on DHT).
    pub envelope: ContentEnvelope,
}

/// Result of decrypting content.
pub struct DecryptedContent {
    /// The plaintext content bytes (held in memory only).
    pub plaintext: Vec<u8>,
    /// The MIME type.
    pub mime_type: String,
    /// The privacy level.
    pub privacy: ContentPrivacy,
}

/// Encrypt content with the Spheres privacy protocol.
pub async fn encrypt_content<C: CryptoSystem>(
    crypto: &C,
    content: &[u8],
    mime_type: &str,
    privacy: ContentPrivacy,
    creator_keypair: &KeyPair,
    group_key: Option<&SharedSecret>,
) -> Result<EncryptedContent> {
    let creator_public = creator_keypair.key().to_string();

    // Public content: sign but don't encrypt
    if privacy == ContentPrivacy::Public {
        let signature = crypto
            .sign(&creator_keypair.key(), &creator_keypair.secret(), content)
            .map_err(|e: VeilidAPIError| crate::SpheresError::CryptoError(e.to_string()))?;

        let content_hash = compute_hash(content);
        let envelope = ContentEnvelope {
            version: 1,
            creator: creator_public,
            privacy,
            content_hash,
            content_nonce: vec![],
            mime_type: mime_type.to_string(),
            content_size: content.len() as u64,
            created_at: chrono::Utc::now().timestamp(),
            wrapped_keys: vec![],
            signature: Some(signature.value().bytes().to_vec()),
        };

        return Ok(EncryptedContent {
            encrypted_bytes: content.to_vec(), // plaintext for public
            envelope,
        });
    }

    // Generate unique content key (256-bit)
    let content_key = crypto.random_shared_secret();

    // Generate random nonce for content
    let content_nonce = crypto.random_nonce();

    // Encrypt content with content key
    let encrypted_bytes = crypto
        .encrypt_aead(content, &content_nonce, &content_key, None)
        .map_err(|e: VeilidAPIError| crate::SpheresError::CryptoError(e.to_string()))?;

    let content_hash = compute_hash(&encrypted_bytes);

    // Build wrapped keys based on privacy level
    let mut wrapped_keys = Vec::new();

    // Always wrap for self (creator can always view their own content)
    let self_wrapped = wrap_key_for_self(crypto, &content_key, creator_keypair)?;
    wrapped_keys.push(self_wrapped);

    match &privacy {
        ContentPrivacy::OnlyMe => {
            // Only self key needed — already added above
        }
        ContentPrivacy::Individual { recipient } => {
            // Wrap for the specific recipient using DH shared secret
            let recipient_key = PublicKey::from_str(recipient)
                .map_err(|e| crate::SpheresError::CryptoError(e.to_string()))?;
            let wrapped = wrap_key_for_recipient(
                crypto,
                &content_key,
                creator_keypair,
                &recipient_key,
            )?;
            wrapped_keys.push(wrapped);
        }
        ContentPrivacy::Group { group_id, epoch: _ } => {
            // Wrap with group key
            let gk = group_key
                .ok_or_else(|| crate::SpheresError::CryptoError("Group key required".into()))?;
            let wrapped = wrap_key_for_group(crypto, &content_key, gk, group_id)?;
            wrapped_keys.push(wrapped);
        }
        ContentPrivacy::Public => unreachable!(),
    }

    let mut envelope = ContentEnvelope {
        version: 1,
        creator: creator_public,
        privacy,
        content_hash,
        content_nonce: content_nonce.as_ref().to_vec(),
        mime_type: mime_type.to_string(),
        content_size: content.len() as u64,
        created_at: chrono::Utc::now().timestamp(),
        wrapped_keys,
        signature: None,
    };

    // Sign the envelope
    let envelope_bytes = serde_json::to_vec(&envelope)
        .map_err(crate::SpheresError::Serialization)?;
    let signature = crypto
        .sign(&creator_keypair.key(), &creator_keypair.secret(), &envelope_bytes)
        .map_err(|e: VeilidAPIError| crate::SpheresError::CryptoError(e.to_string()))?;
    envelope.signature = Some(signature.value().bytes().to_vec());

    Ok(EncryptedContent {
        encrypted_bytes,
        envelope,
    })
}

/// Decrypt content using the Spheres privacy protocol.
pub async fn decrypt_content<C: CryptoSystem>(
    crypto: &C,
    encrypted_bytes: &[u8],
    envelope: &ContentEnvelope,
    reader_keypair: &KeyPair,
    group_key: Option<&SharedSecret>,
) -> Result<DecryptedContent> {
    // Public content: verify signature, return plaintext
    if envelope.privacy == ContentPrivacy::Public {
        // Verify creator signature
        if let Some(sig_bytes) = &envelope.signature {
            let creator_key = PublicKey::from_str(&envelope.creator)
                .map_err(|e| crate::SpheresError::CryptoError(e.to_string()))?;
            let signature = Signature::try_from(sig_bytes.as_slice())
                .map_err(|e| crate::SpheresError::CryptoError(e.to_string()))?;
            let valid = crypto
                .verify(&creator_key, encrypted_bytes, &signature)
                .map_err(|e: VeilidAPIError| crate::SpheresError::CryptoError(e.to_string()))?;
            if !valid {
                return Err(crate::SpheresError::CryptoError("Invalid signature".into()));
            }
        }
        return Ok(DecryptedContent {
            plaintext: encrypted_bytes.to_vec(),
            mime_type: envelope.mime_type.clone(),
            privacy: envelope.privacy.clone(),
        });
    }

    // Verify content hash
    let hash = compute_hash(encrypted_bytes);
    if hash != envelope.content_hash {
        return Err(crate::SpheresError::CryptoError(
            "Content hash mismatch — data may be corrupted".into(),
        ));
    }

    // Find and unwrap the content key
    let reader_public = reader_keypair.key().to_string();
    let content_key = unwrap_content_key(
        crypto,
        envelope,
        reader_keypair,
        &reader_public,
        group_key,
    )?;

    let content_nonce = Nonce::try_from(envelope.content_nonce.as_slice())
        .map_err(|e| crate::SpheresError::CryptoError(e.to_string()))?;

    // Decrypt content
    let plaintext = crypto
        .decrypt_aead(encrypted_bytes, &content_nonce, &content_key, None)
        .map_err(|e: VeilidAPIError| crate::SpheresError::CryptoError(e.to_string()))?;

    Ok(DecryptedContent {
        plaintext,
        mime_type: envelope.mime_type.clone(),
        privacy: envelope.privacy.clone(),
    })
}

// ── Internal helpers ─────────────────────────────────────────────────────────

/// Wrap the content key for the creator (self-encryption).
fn wrap_key_for_self<C: CryptoSystem>(
    crypto: &C,
    content_key: &SharedSecret,
    creator_keypair: &KeyPair,
) -> Result<WrappedKey> {
    // Use a deterministic device key derived from the creator's secret
    let device_key = crypto
        .cached_dh(&creator_keypair.key(), &creator_keypair.secret())
        .map_err(|e: VeilidAPIError| crate::SpheresError::CryptoError(e.to_string()))?;

    let key_nonce = crypto.random_nonce();

    let wrapped = crypto
        .encrypt_aead(content_key.value().bytes(), &key_nonce, &device_key, None)
        .map_err(|e: VeilidAPIError| crate::SpheresError::CryptoError(e.to_string()))?;

    Ok(WrappedKey {
        recipient: creator_keypair.key().to_string(),
        wrapped_content_key: wrapped,
        key_nonce: key_nonce.as_ref().to_vec(),
        method: "self-xchacha20".to_string(),
    })
}

/// Wrap the content key for a specific recipient using DH key exchange.
fn wrap_key_for_recipient<C: CryptoSystem>(
    crypto: &C,
    content_key: &SharedSecret,
    creator_keypair: &KeyPair,
    recipient_public: &PublicKey,
) -> Result<WrappedKey> {
    let shared_secret = crypto
        .cached_dh(recipient_public, &creator_keypair.secret())
        .map_err(|e: VeilidAPIError| crate::SpheresError::CryptoError(e.to_string()))?;

    let key_nonce = crypto.random_nonce();

    let wrapped = crypto
        .encrypt_aead(content_key.value().bytes(), &key_nonce, &shared_secret, None)
        .map_err(|e: VeilidAPIError| crate::SpheresError::CryptoError(e.to_string()))?;

    Ok(WrappedKey {
        recipient: recipient_public.to_string(),
        wrapped_content_key: wrapped,
        key_nonce: key_nonce.as_ref().to_vec(),
        method: "x25519-xchacha20".to_string(),
    })
}

/// Wrap the content key with a group symmetric key.
fn wrap_key_for_group<C: CryptoSystem>(
    crypto: &C,
    content_key: &SharedSecret,
    group_key: &SharedSecret,
    group_id: &str,
) -> Result<WrappedKey> {
    let key_nonce = crypto.random_nonce();

    let wrapped = crypto
        .encrypt_aead(content_key.value().bytes(), &key_nonce, group_key, None)
        .map_err(|e: VeilidAPIError| crate::SpheresError::CryptoError(e.to_string()))?;

    Ok(WrappedKey {
        recipient: format!("group:{}", group_id),
        wrapped_content_key: wrapped,
        key_nonce: key_nonce.as_ref().to_vec(),
        method: "group-xchacha20".to_string(),
    })
}

/// Unwrap the content key from the envelope for a given reader.
fn unwrap_content_key<C: CryptoSystem>(
    crypto: &C,
    envelope: &ContentEnvelope,
    reader_keypair: &KeyPair,
    reader_public_str: &str,
    group_key: Option<&SharedSecret>,
) -> Result<SharedSecret> {
    // Try self key first
    if let Some(entry) = envelope
        .wrapped_keys
        .iter()
        .find(|k| k.recipient == reader_public_str && k.method == "self-xchacha20")
    {
        let device_key = crypto
            .cached_dh(&reader_keypair.key(), &reader_keypair.secret())
            .map_err(|e: VeilidAPIError| crate::SpheresError::CryptoError(e.to_string()))?;

        let key_nonce = Nonce::try_from(entry.key_nonce.as_slice())
            .map_err(|e| crate::SpheresError::CryptoError(e.to_string()))?;

        let key_bytes = crypto
            .decrypt_aead(&entry.wrapped_content_key, &key_nonce, &device_key, None)
            .map_err(|e: VeilidAPIError| crate::SpheresError::CryptoError(e.to_string()))?;

        return SharedSecret::try_from(key_bytes.as_slice())
            .map_err(|e| crate::SpheresError::CryptoError(e.to_string()));
    }

    // Try individual DH key
    if let Some(entry) = envelope
        .wrapped_keys
        .iter()
        .find(|k| k.recipient == reader_public_str && k.method == "x25519-xchacha20")
    {
        let creator_public = PublicKey::from_str(&envelope.creator)
            .map_err(|e| crate::SpheresError::CryptoError(e.to_string()))?;
        let shared_secret = crypto
            .cached_dh(&creator_public, &reader_keypair.secret())
            .map_err(|e: VeilidAPIError| crate::SpheresError::CryptoError(e.to_string()))?;

        let key_nonce = Nonce::try_from(entry.key_nonce.as_slice())
            .map_err(|e| crate::SpheresError::CryptoError(e.to_string()))?;

        let key_bytes = crypto
            .decrypt_aead(&entry.wrapped_content_key, &key_nonce, &shared_secret, None)
            .map_err(|e: VeilidAPIError| crate::SpheresError::CryptoError(e.to_string()))?;

        return SharedSecret::try_from(key_bytes.as_slice())
            .map_err(|e| crate::SpheresError::CryptoError(e.to_string()));
    }

    // Try group key
    if let Some(gk) = group_key {
        if let Some(entry) = envelope
            .wrapped_keys
            .iter()
            .find(|k| k.method == "group-xchacha20")
        {
            let key_nonce = Nonce::try_from(entry.key_nonce.as_slice())
                .map_err(|e| crate::SpheresError::CryptoError(e.to_string()))?;

            let key_bytes = crypto
                .decrypt_aead(&entry.wrapped_content_key, &key_nonce, gk, None)
                .map_err(|e: VeilidAPIError| crate::SpheresError::CryptoError(e.to_string()))?;

            return SharedSecret::try_from(key_bytes.as_slice())
                .map_err(|e| crate::SpheresError::CryptoError(e.to_string()));
        }
    }

    Err(crate::SpheresError::CryptoError(
        "No matching key found — you are not authorized to decrypt this content".into(),
    ))
}

/// Compute BLAKE3 hash of data (hex string).
fn compute_hash(data: &[u8]) -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    // Placeholder: use DefaultHasher until BLAKE3 is available
    // In production, use: blake3::hash(data).to_hex().to_string()
    let mut hasher = DefaultHasher::new();
    data.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}
