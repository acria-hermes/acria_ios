//
// Copyright 2019-2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

//! iOS Platform

use std::collections::HashMap;
use std::ffi::c_void;
use std::fmt;
use std::sync::Arc;

use crate::common::{
    ApplicationEvent,
    CallDirection,
    CallId,
    CallMediaType,
    DeviceId,
    HttpMethod,
    Result,
};
use crate::core::bandwidth_mode::BandwidthMode;
use crate::core::call::Call;
use crate::core::connection::{Connection, ConnectionType};
use crate::core::platform::{Platform, PlatformItem};
use crate::core::{group_call, signaling};
use crate::ios::api::call_manager_interface::{
    AppByteSlice,
    AppCallContext,
    AppConnectionInterface,
    AppHeader,
    AppHeaderArray,
    AppIceCandidateArray,
    AppInterface,
    AppObject,
    AppOptionalBool,
    AppOptionalUInt32,
    AppRemoteDeviceState,
    AppRemoteDeviceStateArray,
    AppUuidArray,
};
use crate::ios::error::IOSError;
use crate::ios::ios_media_stream::IOSMediaStream;
use crate::webrtc::media::{MediaStream, VideoTrack};
use crate::webrtc::peer_connection::{PeerConnection, RffiPeerConnection};
use crate::webrtc::peer_connection_observer::PeerConnectionObserver;

/// Concrete type for iOS AppIncomingMedia objects.
impl PlatformItem for IOSMediaStream {}

/// Concrete type for iOS AppConnection objects.
// @todo Make a type of connection with an Arc. Finalize better naming...
pub type AppConnectionX = Arc<AppConnectionInterface>;
impl PlatformItem for AppConnectionX {}

/// Concrete type for iOS AppCallContext objects.
pub type AppCallContextX = Arc<AppCallContext>;
impl PlatformItem for AppCallContextX {}

/// Concrete type for iOS AppRemotePeer objects.
impl PlatformItem for AppObject {}

/// iOS implementation of platform::Platform.
pub struct IOSPlatform {
    ///
    app_interface: AppInterface,
}

unsafe impl Sync for IOSPlatform {}
unsafe impl Send for IOSPlatform {}

impl fmt::Display for IOSPlatform {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        /*        let jni_owned_pc = match self.jni_owned_pc {
                    Some(v) => format!("0x{:x}", v),
                    None    => "None".to_string(),
                };
        */
        write!(f, "[n/a]")
    }
}

impl fmt::Debug for IOSPlatform {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self)
    }
}

impl Drop for IOSPlatform {
    fn drop(&mut self) {
        info!("Dropping IOSPlatform");

        // Not currently dropping anything explicitly.
    }
}

impl Platform for IOSPlatform {
    type AppIncomingMedia = IOSMediaStream;
    type AppRemotePeer = AppObject;
    type AppConnection = AppConnectionX;
    type AppCallContext = AppCallContextX;

    fn create_connection(
        &mut self,
        call: &Call<Self>,
        remote_device_id: DeviceId,
        connection_type: ConnectionType,
        signaling_version: signaling::Version,
        bandwidth_mode: BandwidthMode,
    ) -> Result<Connection<Self>> {
        info!(
            "create_connection(): call_id: {} remote_device_id: {}, signaling_version: {:?}, bandwidth_mode: {}",
            call.call_id(),
            remote_device_id,
            signaling_version,
            bandwidth_mode
        );

        let connection = Connection::new(
            call.clone(),
            remote_device_id,
            connection_type,
            bandwidth_mode,
        )?;

        let connection_ptr = connection.get_connection_ptr()?;

        // Get the observer because we will need it when creating the
        // PeerConnection in Swift.
        let pc_observer =
            PeerConnectionObserver::new(connection_ptr, false /* enable_frame_encryption */)?;

        let app_connection_interface = (self.app_interface.onCreateConnectionInterface)(
            self.app_interface.object,
            pc_observer.rffi() as *mut c_void,
            remote_device_id,
            call.call_context()?.object,
            signaling_version.enable_dtls(),
            true, /* always enable the RTP data channel */
        );

        if app_connection_interface.object.is_null() || app_connection_interface.pc.is_null() {
            return Err(IOSError::CreateAppPeerConnection.into());
        }

        debug!("app_connection_interface: {}", app_connection_interface);

        // Finish up the connection creation...

        // Retrieve the underlying PeerConnection object from the
        // application owned RTCPeerConnection object.
        let rffi_peer_connection = app_connection_interface.pc as *const RffiPeerConnection;
        if rffi_peer_connection.is_null() {
            return Err(IOSError::ExtractNativePeerConnection.into());
        }

        let peer_connection = PeerConnection::unowned(rffi_peer_connection, pc_observer.rffi());

        connection.set_peer_connection(peer_connection)?;

        info!("connection: {:?}", connection);

        connection.set_app_connection(Arc::new(app_connection_interface))?;

        debug!("Done with create_connection!");

        Ok(connection)
    }

    fn on_start_call(
        &self,
        remote_peer: &Self::AppRemotePeer,
        call_id: CallId,
        direction: CallDirection,
        call_media_type: CallMediaType,
    ) -> Result<()> {
        info!("on_start_call(): id: {}, direction: {}", call_id, direction);

        (self.app_interface.onStartCall)(
            self.app_interface.object,
            remote_peer.ptr,
            u64::from(call_id) as u64,
            direction == CallDirection::OutGoing,
            call_media_type as i32,
        );

        Ok(())
    }

    fn on_event(&self, remote_peer: &Self::AppRemotePeer, event: ApplicationEvent) -> Result<()> {
        info!("on_event(): {}", event);

        (self.app_interface.onEvent)(self.app_interface.object, remote_peer.ptr, event as i32);

        Ok(())
    }

    fn on_send_offer(
        &self,
        remote_peer: &Self::AppRemotePeer,
        call_id: CallId,
        offer: signaling::Offer,
    ) -> Result<()> {
        // Offer messages are always broadcast
        let broadcast = true;
        let receiver_device_id = 0u32;

        info!("on_send_offer(): call_id: {}", call_id);

        (self.app_interface.onSendOffer)(
            self.app_interface.object,
            u64::from(call_id) as u64,
            remote_peer.ptr,
            receiver_device_id,
            broadcast,
            app_slice_from_bytes(Some(&offer.opaque)),
            offer.call_media_type as i32,
        );

        Ok(())
    }

    fn on_send_answer(
        &self,
        remote_peer: &Self::AppRemotePeer,
        call_id: CallId,
        send: signaling::SendAnswer,
    ) -> Result<()> {
        // Answers are never broadcast
        let broadcast = false;
        let receiver_device_id = send.receiver_device_id;

        info!(
            "on_send_answer(): call_id: {}, receiver_device_id: {}",
            call_id, receiver_device_id
        );

        (self.app_interface.onSendAnswer)(
            self.app_interface.object,
            u64::from(call_id) as u64,
            remote_peer.ptr,
            receiver_device_id,
            broadcast,
            app_slice_from_bytes(Some(&send.answer.opaque)),
        );

        Ok(())
    }

    fn on_send_ice(
        &self,
        remote_peer: &Self::AppRemotePeer,
        call_id: CallId,
        send: signaling::SendIce,
    ) -> Result<()> {
        let (broadcast, receiver_device_id) = match send.receiver_device_id {
            // The DeviceId doesn't matter if we're broadcasting
            None => (true, 0),
            Some(receiver_device_id) => (false, receiver_device_id),
        };

        info!(
            "on_send_ice(): call_id: {}, receiver_device_id: {}, broadcast: {}",
            call_id, receiver_device_id, broadcast
        );

        if send.ice.candidates_added.is_empty() {
            return Ok(());
        }

        let mut app_ice_candidates: Vec<AppByteSlice> = Vec::new();

        for candidate in &send.ice.candidates_added {
            let app_ice_candidate = app_slice_from_bytes(Some(&candidate.opaque));
            app_ice_candidates.push(app_ice_candidate);
        }

        let app_ice_candidates_array = AppIceCandidateArray {
            candidates: app_ice_candidates.as_ptr(),
            count:      app_ice_candidates.len(),
        };

        // The app_ice_candidates_array is passed up by reference and must
        // be consumed by the integration layer before returning.
        (self.app_interface.onSendIceCandidates)(
            self.app_interface.object,
            u64::from(call_id) as u64,
            remote_peer.ptr,
            receiver_device_id,
            broadcast,
            &app_ice_candidates_array,
        );

        Ok(())
    }

    fn on_send_hangup(
        &self,
        remote_peer: &Self::AppRemotePeer,
        call_id: CallId,
        send: signaling::SendHangup,
    ) -> Result<()> {
        // Hangups are always broadcast
        let broadcast = true;
        let receiver_device_id = 0;

        info!("on_send_hangup(): call_id: {}", call_id);

        let (hangup_type, hangup_device_id) = send.hangup.to_type_and_device_id();
        // We set the device_id to 0 in case it is not defined. It will
        // only be used for hangup types other than Normal.
        let hangup_device_id = hangup_device_id.unwrap_or(0);

        (self.app_interface.onSendHangup)(
            self.app_interface.object,
            u64::from(call_id) as u64,
            remote_peer.ptr,
            receiver_device_id,
            broadcast,
            hangup_type as i32,
            hangup_device_id,
            send.use_legacy,
        );

        Ok(())
    }

    fn on_send_busy(&self, remote_peer: &Self::AppRemotePeer, call_id: CallId) -> Result<()> {
        // Busy messages are always broadcast
        let broadcast = true;
        let receiver_device_id = 0;

        info!("on_send_busy(): call_id: {}", call_id);

        (self.app_interface.onSendBusy)(
            self.app_interface.object,
            u64::from(call_id) as u64,
            remote_peer.ptr,
            receiver_device_id,
            broadcast,
        );

        Ok(())
    }

    fn send_call_message(&self, recipient_uuid: Vec<u8>, message: Vec<u8>) -> Result<()> {
        info!("send_call_message():");

        (self.app_interface.sendCallMessage)(
            self.app_interface.object,
            app_slice_from_bytes(Some(&recipient_uuid)),
            app_slice_from_bytes(Some(&message)),
        );

        Ok(())
    }

    fn send_http_request(
        &self,
        request_id: u32,
        url: String,
        method: HttpMethod,
        headers: HashMap<String, String>,
        body: Option<Vec<u8>>,
    ) -> Result<()> {
        info!("send_http_request(): request_id: {}", request_id);

        let mut app_headers: Vec<AppHeader> = Vec::new();

        for (name, value) in headers.iter() {
            let app_header = AppHeader {
                name:  app_slice_from_str(Some(&name)),
                value: app_slice_from_str(Some(&value)),
            };

            app_headers.push(app_header);
        }

        let app_header_array = AppHeaderArray {
            headers: app_headers.as_ptr(),
            count:   app_headers.len(),
        };

        (self.app_interface.sendHttpRequest)(
            self.app_interface.object,
            request_id,
            app_slice_from_str(Some(&url)),
            method as i32,
            app_header_array,
            app_slice_from_bytes(body.as_ref()),
        );

        Ok(())
    }

    fn create_incoming_media(
        &self,
        connection: &Connection<Self>,
        incoming_media: MediaStream,
    ) -> Result<Self::AppIncomingMedia> {
        info!("create_incoming_media():");

        let app_connection_interface = connection.app_connection()?;

        // Create application level "AppMediaStreamInterface" object from here, which is created by
        // the Swift side.
        let app_media_stream_interface = (self.app_interface.onCreateMediaStreamInterface)(
            self.app_interface.object,
            app_connection_interface.object,
        );

        if app_media_stream_interface.object.is_null() {
            return Err(IOSError::CreateAppMediaStream.into());
        }

        // Pass this object and give ownership to a new IOSMediaStream object.
        IOSMediaStream::new(app_media_stream_interface, incoming_media)
    }

    fn connect_incoming_media(
        &self,
        remote_peer: &Self::AppRemotePeer,
        app_call_context: &Self::AppCallContext,
        incoming_media: &Self::AppIncomingMedia,
    ) -> Result<()> {
        info!("connect_incoming_media():");

        let ios_media_stream = incoming_media as &IOSMediaStream;
        let app_media_stream = ios_media_stream.get_ref()?;

        (self.app_interface.onConnectMedia)(
            self.app_interface.object,
            remote_peer.ptr,
            app_call_context.object,
            app_media_stream,
        );

        Ok(())
    }

    fn compare_remotes(
        &self,
        remote_peer1: &Self::AppRemotePeer,
        remote_peer2: &Self::AppRemotePeer,
    ) -> Result<bool> {
        info!("compare_remotes():");

        let result = (self.app_interface.onCompareRemotes)(
            self.app_interface.object,
            remote_peer1.ptr,
            remote_peer2.ptr,
        );

        Ok(result)
    }

    fn on_call_concluded(&self, remote_peer: &Self::AppRemotePeer) -> Result<()> {
        info!("on_call_concluded():");

        (self.app_interface.onCallConcluded)(self.app_interface.object, remote_peer.ptr);

        Ok(())
    }

    // Group Calls

    fn handle_peek_response(
        &self,
        request_id: u32,
        joined_members: &[group_call::UserId],
        creator: Option<group_call::UserId>,
        era_id: Option<&str>,
        max_devices: Option<u32>,
        device_count: u32,
    ) {
        let mut app_joined_members: Vec<AppByteSlice> = Vec::new();

        for member in joined_members {
            let app_joined_member = app_slice_from_bytes(Some(&member));
            app_joined_members.push(app_joined_member);
        }

        let app_joined_members_array = AppUuidArray {
            uuids: app_joined_members.as_ptr(),
            count: app_joined_members.len(),
        };

        let app_creator = app_slice_from_bytes(creator.as_ref());
        let era_id = era_id.map(String::from);
        let app_era_id = app_slice_from_str(era_id.as_ref());

        let app_max_devices = app_option_from_u32(max_devices);

        (self.app_interface.handlePeekResponse)(
            self.app_interface.object,
            request_id,
            app_joined_members_array,
            app_creator,
            app_era_id,
            app_max_devices,
            device_count,
        );
    }

    fn request_membership_proof(&self, client_id: group_call::ClientId) {
        (self.app_interface.requestMembershipProof)(self.app_interface.object, client_id);
    }

    fn request_group_members(&self, client_id: group_call::ClientId) {
        (self.app_interface.requestGroupMembers)(self.app_interface.object, client_id);
    }

    fn handle_connection_state_changed(
        &self,
        client_id: group_call::ClientId,
        connection_state: group_call::ConnectionState,
    ) {
        (self.app_interface.handleConnectionStateChanged)(
            self.app_interface.object,
            client_id,
            connection_state as i32,
        );
    }

    fn handle_join_state_changed(
        &self,
        client_id: group_call::ClientId,
        join_state: group_call::JoinState,
    ) {
        (self.app_interface.handleJoinStateChanged)(
            self.app_interface.object,
            client_id,
            match join_state {
                group_call::JoinState::NotJoined => 0,
                group_call::JoinState::Joining => 1,
                group_call::JoinState::Joined(_, _) => 2,
            },
        );
    }

    fn handle_remote_devices_changed(
        &self,
        client_id: group_call::ClientId,
        remote_device_states: &[group_call::RemoteDeviceState],
    ) {
        let mut app_remote_device_states: Vec<AppRemoteDeviceState> = Vec::new();

        for remote_device_state in remote_device_states {
            let app_remote_device_state = AppRemoteDeviceState {
                demuxId:           remote_device_state.demux_id,
                user_id:           app_slice_from_bytes(Some(remote_device_state.user_id.as_ref())),
                mediaKeysReceived: remote_device_state.media_keys_received,
                audioMuted:        app_option_from_bool(remote_device_state.audio_muted),
                videoMuted:        app_option_from_bool(remote_device_state.video_muted),
                addedTime:         remote_device_state.added_time_as_unix_millis(),
                speakerTime:       remote_device_state.speaker_time_as_unix_millis(),
            };

            app_remote_device_states.push(app_remote_device_state);
        }

        let app_remote_device_states_array = AppRemoteDeviceStateArray {
            states: app_remote_device_states.as_ptr(),
            count:  app_remote_device_states.len(),
        };

        (self.app_interface.handleRemoteDevicesChanged)(
            self.app_interface.object,
            client_id,
            app_remote_device_states_array,
        );
    }

    fn handle_incoming_video_track(
        &self,
        client_id: group_call::ClientId,
        remote_demux_id: group_call::DemuxId,
        incoming_video_track: VideoTrack,
    ) {
        (self.app_interface.handleIncomingVideoTrack)(
            self.app_interface.object,
            client_id,
            remote_demux_id,
            incoming_video_track.rffi() as *mut c_void,
        );
    }

    fn handle_peek_changed(
        &self,
        client_id: group_call::ClientId,
        joined_members: &[group_call::UserId],
        creator: Option<group_call::UserId>,
        era_id: Option<&str>,
        max_devices: Option<u32>,
        device_count: u32,
    ) {
        let mut app_joined_members: Vec<AppByteSlice> = Vec::new();

        for member in joined_members {
            let app_joined_member = app_slice_from_bytes(Some(member));
            app_joined_members.push(app_joined_member);
        }

        let app_joined_members_array = AppUuidArray {
            uuids: app_joined_members.as_ptr(),
            count: app_joined_members.len(),
        };

        let app_creator = app_slice_from_bytes(creator.as_ref());
        let era_id = era_id.map(String::from);
        let app_era_id = app_slice_from_str(era_id.as_ref());

        let app_max_devices = app_option_from_u32(max_devices);

        (self.app_interface.handlePeekChanged)(
            self.app_interface.object,
            client_id,
            app_joined_members_array,
            app_creator,
            app_era_id,
            app_max_devices,
            device_count,
        );
    }

    fn handle_ended(&self, client_id: group_call::ClientId, reason: group_call::EndReason) {
        (self.app_interface.handleEnded)(self.app_interface.object, client_id, reason as i32);
    }
}

impl IOSPlatform {
    /// Create a new IOSPlatform object.
    pub fn new(
        app_call_manager_interface: *mut c_void,
        app_interface: AppInterface,
    ) -> Result<Self> {
        debug!(
            "IOSPlatform::new: {:?} {:?}",
            app_call_manager_interface, app_interface
        );

        Ok(Self { app_interface })
    }
}

fn app_slice_from_bytes(bytes: Option<&Vec<u8>>) -> AppByteSlice {
    match bytes {
        None => AppByteSlice {
            bytes: std::ptr::null(),
            len:   0,
        },
        Some(bytes) => AppByteSlice {
            bytes: bytes.as_ptr(),
            len:   bytes.len(),
        },
    }
}

fn app_slice_from_str(s: Option<&String>) -> AppByteSlice {
    match s {
        None => AppByteSlice {
            bytes: std::ptr::null(),
            len:   0,
        },
        Some(s) => AppByteSlice {
            bytes: s.as_ptr(),
            len:   s.len(),
        },
    }
}

fn app_option_from_u32(v: Option<u32>) -> AppOptionalUInt32 {
    match v {
        None => AppOptionalUInt32 {
            value: 0, // <- app should ignore
            valid: false,
        },
        Some(v) => AppOptionalUInt32 {
            value: v,
            valid: true,
        },
    }
}

fn app_option_from_bool(v: Option<bool>) -> AppOptionalBool {
    match v {
        None => AppOptionalBool {
            value: false, // <- app should ignore
            valid: false,
        },
        Some(v) => AppOptionalBool {
            value: v,
            valid: true,
        },
    }
}
