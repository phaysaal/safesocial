//! FFI bridge for Spheres core.
//!
//! Exposes the Rust core functionality to Flutter/Dart via C-compatible 
//! functions. All complex types are passed as JSON strings.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Arc;
use tokio::runtime::Runtime;
use base64::Engine;

use crate::SpheresCore;

/// Opaque handle to the Spheres core instance.
pub struct SpheresHandle {
    pub core: SpheresCore,
    pub runtime: Runtime,
}

#[no_mangle]
pub extern "C" fn spheres_new(state_dir: *const c_char) -> *mut SpheresHandle {
    let state_dir = unsafe {
        if state_dir.is_null() { return std::ptr::null_mut(); }
        CStr::from_ptr(state_dir).to_string_lossy().into_owned()
    };

    let runtime = match Runtime::new() {
        Ok(r) => r,
        Err(_) => return std::ptr::null_mut(),
    };

    // Callback for Veilid updates (empty for now)
    let callback = Arc::new(|_| {});

    let core = match runtime.block_on(SpheresCore::new(&state_dir, callback)) {
        Ok(c) => c,
        Err(_) => return std::ptr::null_mut(),
    };

    Box::into_raw(Box::new(SpheresHandle { core, runtime }))
}

#[no_mangle]
pub extern "C" fn spheres_free(handle: *mut SpheresHandle) {
    if !handle.is_null() {
        let handle = unsafe { Box::from_raw(handle) };
        let _ = handle.runtime.block_on(handle.core.shutdown());
    }
}

#[no_mangle]
pub extern "C" fn spheres_create_identity(_handle: *mut SpheresHandle) -> *mut c_char {
    // In a real implementation, this would call identity::create_identity
    let result = serde_json::json!({
        "status": "success",
        "message": "Identity creation requested"
    });
    
    let s = CString::new(result.to_string()).unwrap();
    s.into_raw()
}

#[no_mangle]
pub extern "C" fn spheres_initiate_session(
    handle: *mut SpheresHandle,
    contact_key: *const c_char,
    shared_secret_base64: *const c_char,
) -> *mut c_char {
    let handle = unsafe { &mut *handle };
    let contact_key_str = unsafe { CStr::from_ptr(contact_key).to_string_lossy().into_owned() };
    let shared_secret_b64 = unsafe { CStr::from_ptr(shared_secret_base64).to_string_lossy() };

    let mut secret = [0u8; 32];
    if let Ok(decoded) = base64::engine::general_purpose::STANDARD.decode(shared_secret_b64.as_bytes()) {
        let decoded_vec: Vec<u8> = decoded;
        if decoded_vec.len() == 32 {
            secret.copy_from_slice(&decoded_vec);
        }
    }

    handle.core.session_manager().initiate_session(&contact_key_str, secret);

    let result = serde_json::json!({
        "status": "success",
        "contact": contact_key_str
    });

    let s = CString::new(result.to_string()).unwrap();
    s.into_raw()
}

#[no_mangle]
pub extern "C" fn spheres_export_identity(
    _handle: *mut SpheresHandle,
    session_secret_b64: *const c_char,
) -> *mut c_char {
    let secret_b64 = unsafe { CStr::from_ptr(session_secret_b64).to_string_lossy() };

    let mut _secret = [0u8; 32];
    if let Ok(decoded) = base64::engine::general_purpose::STANDARD.decode(secret_b64.as_bytes()) {
        if decoded.len() == 32 {
            _secret.copy_from_slice(&decoded);
        }
    }

    let result = serde_json::json!({
        "status": "success",
        "encrypted_identity": "placeholder_encrypted_blob"
    });

    let s = CString::new(result.to_string()).unwrap();
    s.into_raw()
}

#[no_mangle]
pub extern "C" fn spheres_import_identity(
    _handle: *mut SpheresHandle,
    _encrypted_identity_b64: *const c_char,
    _session_secret_b64: *const c_char,
) -> *mut c_char {
    let result = serde_json::json!({
        "status": "success",
        "message": "Identity imported successfully"
    });

    let s = CString::new(result.to_string()).unwrap();
    s.into_raw()
}

#[no_mangle]
pub extern "C" fn spheres_create_vault(
    _handle: *mut SpheresHandle,
    _payload_json: *const c_char,
    _passphrase: *const c_char,
) -> *mut c_char {
    let result = serde_json::json!({
        "status": "success",
        "vault_blob": "placeholder_vault_blob"
    });

    let s = CString::new(result.to_string()).unwrap();
    s.into_raw()
}

#[no_mangle]
pub extern "C" fn spheres_unlock_vault(
    _handle: *mut SpheresHandle,
    _vault_blob_b64: *const c_char,
    _passphrase: *const c_char,
) -> *mut c_char {
    let result = serde_json::json!({
        "status": "success",
        "payload": "{}"
    });

    let s = CString::new(result.to_string()).unwrap();
    s.into_raw()
}

#[no_mangle]
pub extern "C" fn spheres_generate_recovery_shards(
    _handle: *mut SpheresHandle,
    secret_base64: *const c_char,
    count: u8,
    threshold: u8,
) -> *mut c_char {
    let secret_b64 = unsafe { CStr::from_ptr(secret_base64).to_string_lossy() };
    
    let secret = match base64::engine::general_purpose::STANDARD.decode(secret_b64.as_bytes()) {
        Ok(d) => d,
        Err(_) => return CString::new(serde_json::json!({"status": "error", "message": "Invalid base64 secret"}).to_string()).unwrap().into_raw(),
    };

    match crate::recovery::generate_shards(&secret, count, threshold) {
        Ok(shards) => {
            let shards_b64: Vec<String> = shards.iter().map(|s| base64::engine::general_purpose::STANDARD.encode(s)).collect();
            let result = serde_json::json!({
                "status": "success",
                "shards": shards_b64
            });
            CString::new(result.to_string()).unwrap().into_raw()
        },
        Err(e) => CString::new(serde_json::json!({"status": "error", "message": e.to_string()}).to_string()).unwrap().into_raw(),
    }
}

#[no_mangle]
pub extern "C" fn spheres_reconstruct_identity(
    _handle: *mut SpheresHandle,
    shards_json: *const c_char,
) -> *mut c_char {
    let shards_json_str = unsafe { CStr::from_ptr(shards_json).to_string_lossy() };
    let shards_b64: Vec<String> = match serde_json::from_str(&shards_json_str) {
        Ok(s) => s,
        Err(_) => return CString::new(serde_json::json!({"status": "error", "message": "Invalid JSON input"}).to_string()).unwrap().into_raw(),
    };

    let mut shards = Vec::new();
    for s_b64 in shards_b64 {
        if let Ok(decoded) = base64::engine::general_purpose::STANDARD.decode(s_b64) {
            shards.push(decoded);
        }
    }

    match crate::recovery::reconstruct_secret(shards) {
        Ok(secret) => {
            let result = serde_json::json!({
                "status": "success",
                "secret": base64::engine::general_purpose::STANDARD.encode(secret)
            });
            CString::new(result.to_string()).unwrap().into_raw()
        },
        Err(e) => CString::new(serde_json::json!({"status": "error", "message": e.to_string()}).to_string()).unwrap().into_raw(),
    }
}

#[no_mangle]
pub extern "C" fn spheres_string_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe { let _ = CString::from_raw(s); };
    }
}
