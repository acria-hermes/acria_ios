//
// Copyright 2019-2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

//! Re-exports WebRTC JNI interfaces

use jni::objects::{JClass, JObject};
use jni::sys::{jboolean, jlong};
use jni::JNIEnv;

use crate::webrtc::peer_connection::RffiPeerConnection;

extern "C" {
    /// Export the nativeCreatepeerconnection() call from the
    /// org.webrtc.PeerConnectionFactory class.
    pub fn Java_org_webrtc_PeerConnectionFactory_nativeCreatePeerConnection(
        env: JNIEnv,
        class: JClass,
        factory: jlong,
        rtcConfig: JObject,
        constraints: JObject,
        nativeObserver: jlong,
        sslCertificateVerifier: JObject,
        enable_dtls: jboolean,
        enable_rtp_data_channel: jboolean,
    ) -> jlong;
}

/// Retrieve the underlying PeerConnection object from the
/// JNI OwnedPeerConnection object.
extern "C" {
    pub fn Rust_getPeerConnectionFromJniOwnedPeerConnection(
        jni_owned_pc: i64,
    ) -> *const RffiPeerConnection;
}
