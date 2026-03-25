//! Local contact list management via Veilid TableStore.
//!
//! Contacts are stored entirely on-device in the Veilid TableStore (an
//! encrypted key-value database). They are never published to the DHT.

use serde::{Deserialize, Serialize};
use veilid_core::*;

use crate::schema;
use crate::Result;

/// A single contact entry.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Contact {
    /// The contact's public key (base64-encoded), used as their unique identifier.
    pub public_key: String,
    /// The contact's display name (may be fetched from their profile).
    pub display_name: String,
    /// An optional user-assigned nickname for this contact.
    pub nickname: Option<String>,
    /// Unix timestamp when the contact was added.
    pub added_at: i64,
    /// Whether messages from this contact should be blocked.
    pub blocked: bool,
}

/// A wrapper around a list of contacts, used for serialization.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ContactList {
    /// The contacts in this list.
    pub contacts: Vec<Contact>,
}

const TABLE_NAME: &str = "contacts";
const CONTACT_LIST_KEY: &[u8] = b"contact_list";

/// Persist the full contact list to the local TableStore.
pub async fn save_contacts(api: &VeilidAPI, contacts: &ContactList) -> Result<()> {
    tracing::debug!("Saving {} contacts to table store", contacts.contacts.len());

    let ts = api.table_store()?;
    let db = ts.open(TABLE_NAME, 1).await?;
    let serialized = schema::serialize(contacts)?;
    db.store(0, CONTACT_LIST_KEY, &serialized).await?;

    Ok(())
}

/// Load the contact list from the local TableStore.
///
/// Returns an empty `ContactList` if no data has been stored yet.
pub async fn load_contacts(api: &VeilidAPI) -> Result<ContactList> {
    tracing::debug!("Loading contacts from table store");

    let ts = api.table_store()?;
    let db = ts.open(TABLE_NAME, 1).await?;
    let value: Option<Vec<u8>> = db.load(0, CONTACT_LIST_KEY).await?;

    match value {
        Some(data) => {
            let list: ContactList = schema::deserialize(&data)?;
            tracing::debug!("Loaded {} contacts", list.contacts.len());
            Ok(list)
        }
        None => {
            tracing::debug!("No contacts found, returning empty list");
            Ok(ContactList::default())
        }
    }
}

/// Add a contact to the local contact list.
///
/// The contact is appended to the existing list and the full list is re-saved.
pub async fn add_contact(api: &VeilidAPI, contact: Contact) -> Result<()> {
    tracing::info!("Adding contact: {}", contact.display_name);

    let mut list = load_contacts(api).await?;
    list.contacts.push(contact);
    save_contacts(api, &list).await
}

/// Remove a contact by their public key.
///
/// If the key is not found in the list, this is a no-op.
pub async fn remove_contact(api: &VeilidAPI, public_key: &str) -> Result<()> {
    tracing::info!("Removing contact with key: {}", public_key);

    let mut list = load_contacts(api).await?;
    list.contacts.retain(|c| c.public_key != public_key);
    save_contacts(api, &list).await
}

/// Set or clear the blocked flag on a contact identified by public key.
pub async fn block_contact(api: &VeilidAPI, public_key: &str, blocked: bool) -> Result<()> {
    tracing::info!(
        "Setting blocked={} for contact with key: {}",
        blocked,
        public_key
    );

    let mut list = load_contacts(api).await?;
    for contact in &mut list.contacts {
        if contact.public_key == public_key {
            contact.blocked = blocked;
            break;
        }
    }
    save_contacts(api, &list).await
}
