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
pub extern "C" fn spheres_create_identity(handle: *mut SpheresHandle) -> *mut c_char {
    let _handle = unsafe { &mut *handle };
    
    // In a real implementation, this would call identity::create_identity
    // For now, we return a success status
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
pub extern "C" fn spheres_send_message(
    handle: *mut SpheresHandle,
    recipient_key: *const c_char,
    content: *const c_char,
) -> *mut c_char {
    let _handle = unsafe { &mut *handle };
    let recipient = unsafe { CStr::from_ptr(recipient_key).to_string_lossy() };
    let content = unsafe { CStr::from_ptr(content).to_string_lossy() };

    // This is where we would call messaging::send_message
    // utilizing the session_manager for ratcheting.
    
    let result = serde_json::json!({
        "status": "queued",
        "recipient": recipient,
        "content_length": content.len()
    });

    let s = CString::new(result.to_string()).unwrap();
    s.into_raw()
}

#[no_mangle]
pub extern "C" fn spheres_string_free(s: *mut c_char) {
    if !s.is_null() {
        unsafe { let _ = CString::from_raw(s); };
    }
}
