//
// Copyright 2019-2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

//! Foreign Function Interface utility helpers and types.

use std::ffi::c_void;
use std::mem;
use std::sync::{Arc, Condvar, Mutex};
use std::thread;

#[cfg(any(not(debug_assertions), test))]
use lazy_static::lazy_static;
#[cfg(any(not(debug_assertions), test))]
use regex::Regex;

use futures::future::Future;
use sha2::{Digest, Sha256};
use tokio::runtime;

use crate::common::Result;
use crate::error::RingRtcError;

/// Generic Mutex/Condvar pair for signaling async event completion.
pub type FutureResult<T> = Arc<(Mutex<(bool, T)>, Condvar)>;

/// Opaque pointer type for an object of C++ origin.
pub type CppObject = *const c_void;

/// Opaque pointer type for an object of Rust origin.
pub type RustObject = *const c_void;

/// # Safety
///
/// Dereferences raw *mut T into an Arc<Mutex<T>>.
pub unsafe fn ptr_as_arc_mutex<T>(ptr: *mut T) -> Result<Arc<Mutex<T>>> {
    if ptr.is_null() {
        return Err(RingRtcError::NullPointer(
            "ptr_as_arc_mutex<T>()".to_string(),
            "ptr".to_string(),
        )
        .into());
    }
    let arc = Arc::from_raw(ptr as *mut Mutex<T>);
    Ok(arc)
}

/// Wrapper around an Arc<Mutex<T>> pointer that prevents it from
/// freeing its contents when it goes out of scope.  Useful when
/// translating a Java long into an Arc, when you want the Arc to
/// continue persist.
///
/// If you really want to consume the Arc use ptr_as_arc_mutex()
/// instead.
pub struct ArcPtr<T> {
    arc: Option<Arc<Mutex<T>>>,
}

impl<T> ArcPtr<T> {
    /// # Safety
    ///
    /// Creates a new ArcPtr<T>.
    pub unsafe fn new(ptr: *mut T) -> Self {
        ArcPtr {
            arc: Some(Arc::<Mutex<T>>::from_raw(ptr as *mut Mutex<T>)),
        }
    }

    /// Returns reference to the inner Arc<Mutex<T>>.
    pub fn get_arc(&self) -> &Arc<Mutex<T>> {
        match self.arc {
            Some(ref v) => v,
            None => panic!("Empty ArcPtr"),
        }
    }
}

impl<T> Drop for ArcPtr<T> {
    fn drop(&mut self) {
        let mut swap = None;
        mem::swap(&mut swap, &mut self.arc);
        if let Some(arc) = swap {
            let _ = Arc::into_raw(arc);
        }
    }
}

/// # Safety
///
/// Dereferences raw *mut T into an ArcPtr<T>.
pub unsafe fn ptr_as_arc_ptr<T>(ptr: *mut T) -> Result<ArcPtr<T>> {
    if ptr.is_null() {
        return Err(RingRtcError::NullPointer(
            "ptr_as_arc_ptr<T>()".to_string(),
            "ptr".to_string(),
        )
        .into());
    }
    Ok(ArcPtr::<T>::new(ptr))
}

/// # Safety
///
/// Casts a raw *mut T into a &T.
pub unsafe fn ptr_as_ref<T>(ptr: *mut T) -> Result<&'static T> {
    if ptr.is_null() {
        return Err(
            RingRtcError::NullPointer("ptr_as_ref<T>()".to_string(), "ptr".to_string()).into(),
        );
    }

    let object = &*ptr;
    Ok(object)
}

/// # Safety
///
/// Casts a raw *mut T into a &mut T.
pub unsafe fn ptr_as_mut<T>(ptr: *mut T) -> Result<&'static mut T> {
    if ptr.is_null() {
        return Err(
            RingRtcError::NullPointer("ptr_as_mut<T>()".to_string(), "ptr".to_string()).into(),
        );
    }

    let object = &mut *ptr;
    Ok(object)
}

/// # Safety
///
/// Dereferences raw *mut T into a Box<T>.
pub unsafe fn ptr_as_box<T>(ptr: *mut T) -> Result<Box<T>> {
    if ptr.is_null() {
        return Err(
            RingRtcError::NullPointer("ptr_as_box<T>()".to_string(), "ptr".to_string()).into(),
        );
    }

    let object = Box::from_raw(ptr);
    Ok(object)
}

#[allow(dead_code)]
#[cfg(all(debug_assertions, not(test)))]
fn redact_ice_password(text: &str) -> String {
    text.to_string()
}

#[allow(dead_code)]
#[cfg(any(not(debug_assertions), test))]
fn redact_ice_password(text: &str) -> String {
    let mut lines = text.lines().collect::<Vec<&str>>();

    for line in lines.iter_mut() {
        // Redact entire line as needed to mask Ice Password.
        if line.find("ice-pwd").is_some() {
            *line = "a=ice-pwd:[ REDACTED ]";
        }
    }

    lines.join("\n")
}

// Credit to the bulk of this RE to @syzdek on github.
//
// This RE should match:
//
// - IPv6 addresses
// - zero compressed IPv6 addresses (section 2.2 of rfc5952)
// - link-local IPv6 addresses with zone index (section 11 of rfc4007)
// - IPv4-Embedded IPv6 Address (section 2 of rfc6052)
// - IPv4-mapped IPv6 addresses (section 2.1 of rfc2765)
// - IPv4-translated addresses (section 2.1 of rfc2765)
//
// To make the above easier to understand, the following "pseudo" code replicates the RE:
//
// IPV4SEG  = (25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])
// IPV4ADDR = (IPV4SEG\.){3,3}IPV4SEG
// IPV6SEG  = [0-9a-fA-F]{1,4}
// IPV6ADDR = (
//            fe80:(:IPV6SEG){0,4}%[0-9a-zA-Z]{1,}|  # fe80::7:8%eth0     fe80::7:8%1  (link-local IPv6 addresses with zone index)
//            (::)?(IPV6SEG:){1,4}:IPV4ADDR          # 2001:db8:3:4::192.0.2.33  64:ff9b::192.0.2.33 (IPv4-Embedded IPv6 Address)
//            (IPV6SEG:){7,7}IPV6SEG|                # 1:2:3:4:5:6:7:8
//            (IPV6SEG:){1,1}(:IPV6SEG){1,6}|        # 1::3:4:5:6:7:8     1::3:4:5:6:7:8   1::8
//            (IPV6SEG:){1,2}(:IPV6SEG){1,5}|        # 1::4:5:6:7:8       1:2::4:5:6:7:8   1:2::8
//            (IPV6SEG:){1,3}(:IPV6SEG){1,4}|        # 1::5:6:7:8         1:2:3::5:6:7:8   1:2:3::8
//            (IPV6SEG:){1,4}(:IPV6SEG){1,3}|        # 1::6:7:8           1:2:3:4::6:7:8   1:2:3:4::8
//            (IPV6SEG:){1,5}(:IPV6SEG){1,2}|        # 1::7:8             1:2:3:4:5::7:8   1:2:3:4:5::8
//            (IPV6SEG:){1,6}:IPV6SEG|               # 1::8               1:2:3:4:5:6::8   1:2:3:4:5:6::8
//            (IPV6SEG:){1,7}:|                      # 1::                                 1:2:3:4:5:6:7::
//            ::(ffff(:0{1,4}){0,1}:){0,1}IPV4ADDR|  # ::255.255.255.255  ::ffff:255.255.255.255  ::ffff:0:255.255.255.255 (IPv4-mapped IPv6 addresses and IPv4-translated addresses)
//            :((:IPV6SEG){1,7}|:)|                  # ::2:3:4:5:6:7:8    ::2:3:4:5:6:7:8  ::8       ::
//            )

#[allow(dead_code)]
#[cfg(all(debug_assertions, not(test)))]
fn redact_ipv6(text: &str) -> String {
    text.to_string()
}

#[allow(dead_code)]
#[cfg(any(not(debug_assertions), test))]
fn redact_ipv6(text: &str) -> String {
    lazy_static! {
        static ref RE: Option<Regex> = {
            let re_exps = [
                "[Ff][Ee]80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}",
                "(::)?([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])",
                "([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}",
                "([0-9a-fA-F]{1,4}:){1,1}(:[0-9a-fA-F]{1,4}){1,6}",
                "([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}",
                "([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}",
                "([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}",
                "([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}",
                "([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}",
                "([0-9a-fA-F]{1,4}:){1,7}:",
                "::([fF]{4}(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])",
                ":((:[0-9a-fA-F]{1,4}){1,7}|:)",
            ];
            let re = re_exps.join("|");
            match Regex::new(&re) {
                Ok(v) => Some(v),
                Err(_) => None,
            }
        };
    }

    match &*RE {
        Some(v) => v.replace_all(text, "[REDACTED]").to_string(),
        None => "[REDACTED]".to_string(),
    }
}

#[allow(dead_code)]
#[cfg(all(debug_assertions, not(test)))]
fn redact_ipv4(text: &str) -> String {
    text.to_string()
}

#[allow(dead_code)]
#[cfg(any(not(debug_assertions), test))]
fn redact_ipv4(text: &str) -> String {
    lazy_static! {
        static ref RE: Option<Regex> = {
            let re = "(((25[0-5])|(2[0-4][0-9])|([0-1][0-9]{2,2})|([0-9]{1,2}))\\.){3,3}((25[0-5])|(2[0-4][0-9])|([0-1][0-9]{2,2})|([0-9]{1,2}))";
            match Regex::new(&re) {
                Ok(v) => Some(v),
                Err(_) => None,
            }
        };
    }

    match &*RE {
        Some(v) => v.replace_all(text, "[REDACTED]").to_string(),
        None => "[REDACTED]".to_string(),
    }
}

/// Scrubs off sensitive information from the string for public
/// logging purposes, including:
/// - ICE passwords
/// - IPv4 and IPv6 addresses
#[cfg(not(debug_assertions))]
pub fn redact_string(text: &str) -> String {
    let mut string = redact_ice_password(text);
    string = redact_ipv6(&string);
    redact_ipv4(&string)
}

/// For debug builds, redacting won't do anything.
#[cfg(debug_assertions)]
pub fn redact_string(text: &str) -> String {
    text.to_string()
}

/// Encodes a slice of bytes as a hexadecimal string.
///
/// ```
/// use ringrtc::core::util::bytes_to_hexstring;
///
/// assert_eq!(bytes_to_hexstring(&[]), "");
/// assert_eq!(bytes_to_hexstring(&[0x01, 0xAB, 0xCD]), "01abcd");
/// ```
pub fn bytes_to_hexstring(bytes: &[u8]) -> String {
    let mut result = String::new();
    for byte in bytes {
        let hex_byte = format!("{:02x}", byte);
        result.push_str(&hex_byte);
    }
    result
}

/// Computes a SHA-256 hash of the input value and returns it as a hex string.
///
/// ```
/// use ringrtc::core::util::sha256_as_hexstring;
///
/// assert_eq!(sha256_as_hexstring("abc".as_bytes()), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
/// ```
pub fn sha256_as_hexstring(data: &[u8]) -> String {
    let mut hash = Sha256::new();
    hash.update(data);
    let hash = hash.finalize();

    bytes_to_hexstring(&hash)
}

/// Encodes a slice of bytes representing a UUID as a string. Returns an empty
/// string if the slice of bytes is not the expected size of 16 bytes.
///
/// ```
/// use ringrtc::core::util::uuid_to_string;
///
/// assert_eq!(uuid_to_string(&[]), "");
/// assert_eq!(uuid_to_string(&[0x01, 0xAB, 0xCD]), "");
/// assert_eq!(uuid_to_string(&[0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0x00, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]), "11223344-5566-7788-9900-aabbccddeeff");
/// assert_eq!(uuid_to_string(&[0xb3, 0x9b, 0x70, 0xb0, 0x1c, 0xc8, 0x4b, 0x00, 0xb9, 0x32, 0x18, 0x31, 0x03, 0x76, 0x03, 0x15]), "b39b70b0-1cc8-4b00-b932-183103760315");
/// ```
pub fn uuid_to_string(bytes: &[u8]) -> String {
    if bytes.len() == 16 {
        let mut result = String::with_capacity(36);
        for (i, byte) in bytes.iter().enumerate() {
            let hex_byte = format!("{:02x}", byte);
            result.push_str(&hex_byte);
            if i == 3 || i == 5 || i == 7 || i == 9 {
                result.push('-');
            }
        }
        result
    } else {
        String::new()
    }
}

/// A specially configured tokio::Runtime for processing sequential tasks
/// in the context of a Call or Connection.
/// Pre-configured with the right parameters for single-threaded operation,
/// and can be dropped safely on a different runtime thread.
#[derive(Debug)]
pub struct TaskQueueRuntime {
    rt: Option<runtime::Runtime>,
}

impl Drop for TaskQueueRuntime {
    fn drop(&mut self) {
        // Dropping a runtime blocks until all spawned futures complete.
        // tokio disallows dropping a runtime from a runtime thread and
        // panics when it's done, as it will cause a deadlock if a runtime
        // is dropped from its own thread.
        //   We're dropping runtimes from other runtimes, so to bypass the
        // check, this function spawns a temporary thread whose only
        // purpose is to drop the runtime.
        let rt = self.rt.take();
        let drop_thread = thread::spawn(move || {
            core::mem::drop(rt);
        });
        let _ = drop_thread.join();
    }
}

impl TaskQueueRuntime {
    pub fn new(name: &str) -> Result<Self> {
        let rt = Some(
            runtime::Builder::new_multi_thread()
                .worker_threads(1)
                .max_threads(1)
                .enable_all()
                .thread_name(name)
                .build()?,
        );
        Ok(TaskQueueRuntime { rt })
    }

    pub fn spawn<F>(&self, future: F)
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        self.rt.as_ref().unwrap().spawn(future);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn check_ipv6() {
        let addrs = [
            "fe80::2d8:61ff:fe57:83f6",
            "Fe80::2d8:61ff:fe57:83f6",
            "fE80::2d8:61ff:fe57:83f6",
            "1::7:8",
            "1:2:3:4:5::7:8",
            "1:2:3:4:5::8",
            "1::8",
            "1:2:3:4:5:6::8",
            "1:2:3:4:5:6::8",
            "2021:0db8:85a3:0000:0000:8a2e:0370:7334",
            "2301:db8:85a3::8a2e:370:7334",
            "4601:746:9600:dec1:2d8:61ff:fe57:83f6",
            "fe80::2d8:61ff:fe57:83f6",
            "::1",
            "::0",
            "::",
            "::ffff:0:192.0.2.128",
            "::ffff:192.0.2.128",
            "1::",
            "1:2:3:4:5:6:7::",
            "1::8",
            "1:2:3:4:5:6::8",
            "1:2:3:4:5:6::8",
            "1::7:8",
            "1:2:3:4:5::7:8",
            "1:2:3:4:5::8",
            "1::6:7:8",
            "1:2:3:4::6:7:8",
            "1:2:3:4::8",
            "1::5:6:7:8",
            "1:2:3::5:6:7:8",
            "1:2:3::8",
            "1::4:5:6:7:8",
            "1:2::4:5:6:7:8",
            "1:2::8",
            "1::3:4:5:6:7:8",
            "1::3:4:5:6:7:8",
            "1::8",
            "::2:3:4:5:6:7:8",
            "::2:3:4:5:6:7:8",
            "::8",
            "fe80::7:8%eth0",
            "fe80::7:8%1",
            "::255.255.255.255",
            "::ffff:255.255.255.255",
            "2001:db8:3:4::192.0.2.33",
            "64:ff9b::192.0.2.33",
        ];

        let prefix = ["", "text", "text ", "<", "@"];

        let suffix = ["", " text", ">", "@"];

        for a in addrs.iter() {
            for p in prefix.iter() {
                for s in suffix.iter() {
                    let addr = format!("{}{}{}", p, a, s);
                    let scrubbed = redact_ipv6(&addr);
                    assert_eq!((&addr, scrubbed), (&addr, format!("{}[REDACTED]{}", p, s)));
                }
            }
        }
    }

    #[test]
    fn check_ipv4() {
        let addrs = [
            "0.0.0.0",
            "000.000.000.000",
            "000.000.000.00",
            "000.000.000.0",
            "000.000.00.000",
            "000.000.0.000",
            "000.00.000.000",
            "000.0.000.000",
            "00.000.000.000",
            "0.000.000.000",
            "255.255.255.255",
            "248.255.255.245",
            "228.255.255.225",
            "12.01.0.0",
            "192.008.022.1",
            "192.000.002.1",
            "242.068.0.1",
            "092.168.122.1",
            "002.168.122.1",
            "2.168.122.1",
            "92.168.122.1",
            "242.068.0.1",
            "092.168.2.1",
            "002.8.122.2",
            "2.168.122.9",
            "92.168.122.250",
        ];

        let prefix = ["", "text", "text ", "<", "@"];

        let suffix = ["", " text", ">", "@"];

        for a in addrs.iter() {
            for p in prefix.iter() {
                for s in suffix.iter() {
                    let addr = format!("{}{}{}", p, a, s);
                    let scrubbed = redact_ipv4(&addr);
                    assert_eq!((&addr, scrubbed), (&addr, format!("{}[REDACTED]{}", p, s)));
                }
            }
        }
    }
}
