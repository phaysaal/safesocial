//! Identity management using Ed25519 keypairs.
//!
//! Each SafeSocial user has a single identity keypair stored in the Veilid
//! ProtectedStore. The public key serves as the user's global identifier
//! on the network, and the secret key is used to sign DHT records and
//! decrypt private messages.

use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use veilid_core::*;

use crate::Result;

/// The length of a bare public or secret key in bytes.
const KEY_LENGTH: usize = 32;

/// Generate a new Ed25519 identity keypair and persist it in the ProtectedStore.
///
/// The secret key is stored under `"identity_secret"` and the public key
/// under `"identity_public"`, both as base64-encoded strings.
pub fn create_identity(api: &VeilidAPI) -> Result<KeyPair> {
    tracing::info!("Creating new identity keypair");

    let crypto = api.crypto()?;
    let kind = VALID_CRYPTO_KINDS[0];
    let vcrypto = crypto.get(kind).unwrap();
    let keypair = vcrypto.generate_keypair();

    // Store the secret key in the protected store
    let secret_b64 = BASE64.encode(keypair.value().secret().bytes());
    let public_b64 = BASE64.encode(keypair.value().key().bytes());

    let ps = api.protected_store()?;
    ps.save_user_secret_string("identity_secret", &secret_b64)?;
    ps.save_user_secret_string("identity_public", &public_b64)?;

    tracing::info!("Identity created and stored in protected store");
    Ok(keypair)
}

/// Load an existing identity keypair from the ProtectedStore.
///
/// Returns `None` if no identity has been created yet.
pub fn load_identity(api: &VeilidAPI) -> Result<Option<KeyPair>> {
    tracing::debug!("Loading identity from protected store");

    let ps = api.protected_store()?;

    let secret_str = ps.load_user_secret_string("identity_secret")?;
    let public_str = ps.load_user_secret_string("identity_public")?;

    match (secret_str, public_str) {
        (Some(secret_b64), Some(public_b64)) => {
            let secret_bytes = BASE64.decode(&secret_b64).map_err(|e| {
                crate::SafeSocialError::CryptoError(format!("Failed to decode secret key: {}", e))
            })?;
            let public_bytes = BASE64.decode(&public_b64).map_err(|e| {
                crate::SafeSocialError::CryptoError(format!("Failed to decode public key: {}", e))
            })?;

            if secret_bytes.len() != KEY_LENGTH || public_bytes.len() != KEY_LENGTH {
                return Err(crate::SafeSocialError::CryptoError(
                    "Invalid key length in protected store".to_string(),
                ));
            }

            let secret = BareSecretKey::new(&secret_bytes);
            let public_key = BarePublicKey::new(&public_bytes);
            let bare_keypair = BareKeyPair::new(public_key, secret);

            let kind = VALID_CRYPTO_KINDS[0];
            let typed_keypair = KeyPair::new(kind, bare_keypair);

            tracing::debug!("Identity loaded successfully");
            Ok(Some(typed_keypair))
        }
        _ => {
            tracing::debug!("No identity found in protected store");
            Ok(None)
        }
    }
}

/// Load an existing identity or create a new one if none exists.
///
/// This is the recommended way to obtain the user's identity at startup.
pub fn get_or_create_identity(api: &VeilidAPI) -> Result<KeyPair> {
    match load_identity(api)? {
        Some(keypair) => {
            tracing::info!("Existing identity loaded");
            Ok(keypair)
        }
        None => {
            tracing::info!("No existing identity, creating new one");
            create_identity(api)
        }
    }
}

/// Encode a full keypair (public + secret) as a base64 string.
///
/// This is useful for exporting/backing up the identity. The format is
/// the concatenation of the crypto kind tag, public key bytes, and secret key bytes.
pub fn identity_to_string(keypair: &KeyPair) -> String {
    let mut bytes = Vec::with_capacity(4 + KEY_LENGTH * 2);
    bytes.extend_from_slice(keypair.kind().bytes());
    bytes.extend_from_slice(keypair.value().key().bytes());
    bytes.extend_from_slice(keypair.value().secret().bytes());
    BASE64.encode(&bytes)
}

/// Decode a keypair from a base64-encoded string produced by `identity_to_string`.
pub fn identity_from_string(s: &str) -> Result<KeyPair> {
    let bytes = BASE64.decode(s).map_err(|e| {
        crate::SafeSocialError::CryptoError(format!("Failed to decode identity string: {}", e))
    })?;

    let expected_len = 4 + KEY_LENGTH * 2;
    if bytes.len() != expected_len {
        return Err(crate::SafeSocialError::CryptoError(format!(
            "Invalid identity string length: expected {}, got {}",
            expected_len,
            bytes.len()
        )));
    }

    let kind = CryptoKind::new([bytes[0], bytes[1], bytes[2], bytes[3]]);

    let public_key = BarePublicKey::new(&bytes[4..4 + KEY_LENGTH]);
    let secret = BareSecretKey::new(&bytes[4 + KEY_LENGTH..]);
    let bare_keypair = BareKeyPair::new(public_key, secret);

    Ok(KeyPair::new(kind, bare_keypair))
}

/// Encode a public key as a shareable string.
///
/// Other users can use this string to look up the owner's profile on the
/// Veilid DHT and initiate contact.
pub fn public_key_to_string(key: &PublicKey) -> String {
    let mut bytes = Vec::with_capacity(4 + KEY_LENGTH);
    bytes.extend_from_slice(key.kind().bytes());
    bytes.extend_from_slice(key.value().bytes());
    BASE64.encode(&bytes)
}
