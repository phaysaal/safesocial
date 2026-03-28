//! Social Identity Recovery via Shamir's Secret Sharing.
//!
//! Allows a user to split their recovery key into N shards and distribute them
//! to M trusted contacts. The identity can be reconstructed if the user
//! loses all their devices.

use gf256::shamir::shamir;
use crate::Result;

/// Generates recovery shards for a given secret.
/// 
/// # Arguments
/// * `secret` - The secret recovery key (e.g. 32-byte seed)
/// * `count` - Total number of shards to create (N)
/// * `threshold` - Minimum number of shards required to reconstruct (M)
pub fn generate_shards(secret: &[u8], count: u8, threshold: u8) -> Result<Vec<Vec<u8>>> {
    if threshold > count {
        return Err(crate::SpheresError::Generic("Threshold cannot be greater than count".into()));
    }

    let shards = shamir::generate(secret, count as usize, threshold as usize);
    Ok(shards)
}

/// Reconstructs a secret from a list of shards.
pub fn reconstruct_secret(shards: Vec<Vec<u8>>) -> Result<Vec<u8>> {
    if shards.is_empty() {
        return Err(crate::SpheresError::Generic("No shards provided".into()));
    }

    let secret = shamir::reconstruct(&shards);
    Ok(secret)
}
