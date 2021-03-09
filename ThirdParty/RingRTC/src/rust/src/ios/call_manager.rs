//
// Copyright 2019-2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

//! iOS Call Manager

use std::ffi::c_void;
use std::panic;
use std::sync::Arc;
use std::time::Duration;

use crate::ios::api::call_manager_interface::{AppCallContext, AppInterface, AppObject};
use crate::ios::ios_platform::IOSPlatform;
use crate::ios::logging::{init_logging, IOSLogger};

use crate::common::{CallId, CallMediaType, DeviceId, FeatureLevel, HttpResponse, Result};
use crate::core::bandwidth_mode::BandwidthMode;
use crate::core::call_manager::CallManager;
use crate::core::util::{ptr_as_box, ptr_as_mut, uuid_to_string};
use crate::core::{group_call, signaling};
use crate::error::RingRtcError;
use crate::webrtc::media;

/// Public type for iOS CallManager
pub type IOSCallManager = CallManager<IOSPlatform>;

/// Library initialization routine.
///
/// Sets up the logging infrastructure.
pub fn initialize(log_object: IOSLogger) -> Result<()> {
    init_logging(log_object)?;

    // Set a custom panic handler that uses the logger instead of
    // stderr, which is of no use on Android.
    panic::set_hook(Box::new(|panic_info| {
        error!("Critical error: {}", panic_info);
    }));

    Ok(())
}

/// Creates a new IOSCallManager object.
pub fn create(app_call_manager: *mut c_void, app_interface: AppInterface) -> Result<*mut c_void> {
    info!("create_call_manager():");
    let platform = IOSPlatform::new(app_call_manager, app_interface)?;

    let call_manager = IOSCallManager::new(platform)?;

    let call_manager_box = Box::new(call_manager);
    Ok(Box::into_raw(call_manager_box) as *mut c_void)
}

/// Application notification to start a new call.
pub fn call(
    call_manager: *mut IOSCallManager,
    app_remote: *const c_void,
    call_media_type: CallMediaType,
    app_local_device: DeviceId,
) -> Result<()> {
    let call_manager = unsafe { ptr_as_mut(call_manager)? };

    info!("call():");

    call_manager.call(
        AppObject::from(app_remote),
        call_media_type,
        app_local_device,
    )
}

/// Application notification to proceed with a new call
pub fn proceed(
    call_manager: *mut IOSCallManager,
    call_id: u64,
    app_call_context: AppCallContext,
    bandwidth_mode: BandwidthMode,
) -> Result<()> {
    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    let call_id = CallId::from(call_id);

    info!("proceed(): {}", call_id);

    call_manager.proceed(call_id, Arc::new(app_call_context), bandwidth_mode)
}

/// Application notification that the sending of the previous message was a success.
pub fn message_sent(call_manager: *mut IOSCallManager, call_id: u64) -> Result<()> {
    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    let call_id = CallId::from(call_id);

    info!("message_sent(): call_id: {}", call_id);
    call_manager.message_sent(call_id)
}

/// Application notification that the sending of the previous message was a failure.
pub fn message_send_failure(call_manager: *mut IOSCallManager, call_id: u64) -> Result<()> {
    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    let call_id = CallId::from(call_id);

    info!("message_send_failure(): call_id: {}", call_id);
    call_manager.message_send_failure(call_id)
}

/// Application notification of local hangup.
pub fn hangup(call_manager: *mut IOSCallManager) -> Result<()> {
    let call_manager = unsafe { ptr_as_mut(call_manager)? };

    info!("hangup():");
    call_manager.hangup()
}

/// Application notification of received answer message
#[allow(clippy::too_many_arguments)]
pub fn received_answer(
    call_manager: *mut IOSCallManager,
    call_id: u64,
    sender_device_id: DeviceId,
    opaque: Option<Vec<u8>>,
    sender_device_feature_level: FeatureLevel,
    sender_identity_key: Option<Vec<u8>>,
    receiver_identity_key: Option<Vec<u8>>,
) -> Result<()> {
    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    let call_id = CallId::from(call_id);

    info!(
        "received_answer(): call_id: {} sender_device_id: {}",
        call_id, sender_device_id
    );

    let opaque = match opaque {
        Some(v) => v,
        None => {
            return Err(RingRtcError::OptionValueNotSet(
                "received_answer()".to_owned(),
                "opaque".to_owned(),
            )
            .into());
        }
    };

    let sender_identity_key = match sender_identity_key {
        Some(v) => v,
        None => {
            return Err(RingRtcError::OptionValueNotSet(
                "received_answer()".to_owned(),
                "sender_identity_key".to_owned(),
            )
            .into());
        }
    };

    let receiver_identity_key = match receiver_identity_key {
        Some(v) => v,
        None => {
            return Err(RingRtcError::OptionValueNotSet(
                "received_answer()".to_owned(),
                "receiver_identity_key".to_owned(),
            )
            .into());
        }
    };

    call_manager.received_answer(
        call_id,
        signaling::ReceivedAnswer {
            answer: signaling::Answer::new(opaque)?,
            sender_device_id,
            sender_device_feature_level,
            sender_identity_key,
            receiver_identity_key,
        },
    )
}

/// Application notification of received offer message
#[allow(clippy::too_many_arguments)]
pub fn received_offer(
    call_manager: *mut IOSCallManager,
    call_id: u64,
    remote_peer: *const c_void,
    sender_device_id: DeviceId,
    opaque: Option<Vec<u8>>,
    age_sec: u64,
    call_media_type: CallMediaType,
    receiver_device_id: DeviceId,
    sender_device_feature_level: FeatureLevel,
    receiver_device_is_primary: bool,
    sender_identity_key: Option<Vec<u8>>,
    receiver_identity_key: Option<Vec<u8>>,
) -> Result<()> {
    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    let call_id = CallId::from(call_id);
    let remote_peer = AppObject::from(remote_peer);

    info!(
        "received_offer(): call_id: {} remote_device_id: {}",
        call_id, sender_device_id
    );

    let opaque = match opaque {
        Some(v) => v,
        None => {
            return Err(RingRtcError::OptionValueNotSet(
                "received_offer()".to_owned(),
                "opaque".to_owned(),
            )
            .into());
        }
    };

    let sender_identity_key = match sender_identity_key {
        Some(v) => v,
        None => {
            return Err(RingRtcError::OptionValueNotSet(
                "received_offer()".to_owned(),
                "sender_identity_key".to_owned(),
            )
            .into());
        }
    };

    let receiver_identity_key = match receiver_identity_key {
        Some(v) => v,
        None => {
            return Err(RingRtcError::OptionValueNotSet(
                "received_offer()".to_owned(),
                "receiver_identity_key".to_owned(),
            )
            .into());
        }
    };

    call_manager.received_offer(
        remote_peer,
        call_id,
        signaling::ReceivedOffer {
            offer: signaling::Offer::new(call_media_type, opaque)?,
            age: Duration::from_secs(age_sec),
            sender_device_id,
            sender_device_feature_level,
            receiver_device_id,
            receiver_device_is_primary,
            sender_identity_key,
            receiver_identity_key,
        },
    )
}

/// Application notification to add ICE candidates to a Connection
pub fn received_ice(
    call_manager: *mut IOSCallManager,
    call_id: u64,
    received: signaling::ReceivedIce,
) -> Result<()> {
    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    let call_id = CallId::from(call_id);

    info!(
        "received_ice(): call_id: {} sender_device_id: {} candidates len: {}",
        call_id,
        received.sender_device_id,
        received.ice.candidates_added.len()
    );

    call_manager.received_ice(call_id, received)
}

/// Application notification of received Hangup message
pub fn received_hangup(
    call_manager: *mut IOSCallManager,
    call_id: u64,
    sender_device_id: DeviceId,
    hangup_type: signaling::HangupType,
    hangup_device_id: DeviceId,
) -> Result<()> {
    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    let call_id = CallId::from(call_id);

    info!(
        "received_hangup(): call_id: {} sender device_id: {}",
        call_id, sender_device_id
    );

    call_manager.received_hangup(
        call_id,
        signaling::ReceivedHangup {
            hangup: signaling::Hangup::from_type_and_device_id(hangup_type, hangup_device_id),
            sender_device_id,
        },
    )
}

/// Application notification of received Busy message
pub fn received_busy(
    call_manager: *mut IOSCallManager,
    call_id: u64,
    sender_device_id: DeviceId,
) -> Result<()> {
    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    let call_id = CallId::from(call_id);

    info!(
        "received_busy(): call_id: {} sender device_id: {}",
        call_id, sender_device_id
    );

    call_manager.received_busy(call_id, signaling::ReceivedBusy { sender_device_id })
}

pub fn received_call_message(
    call_manager: *mut IOSCallManager,
    sender_uuid: Vec<u8>,
    sender_device_id: DeviceId,
    local_device_id: DeviceId,
    message: Vec<u8>,
    message_age_sec: u64,
) -> Result<()> {
    info!(
        "received_call_message(): sender_device_id: {}",
        sender_device_id
    );
    debug!("  sender_uuid: {}", uuid_to_string(&sender_uuid));

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.received_call_message(
        sender_uuid,
        sender_device_id,
        local_device_id,
        message,
        message_age_sec,
    )
}

pub fn received_http_response(
    call_manager: *mut IOSCallManager,
    request_id: u32,
    response: Option<HttpResponse>,
) -> Result<()> {
    info!("received_http_response(): request_id: {}", request_id,);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.received_http_response(request_id, response)
}

/// Application notification to accept the incoming call
pub fn accept_call(call_manager: *mut IOSCallManager, call_id: u64) -> Result<()> {
    let call_id = CallId::from(call_id);

    info!("accept_call(): {}", call_id);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.accept_call(call_id)
}

/// CMI request for the active Connection object
pub fn get_active_connection(call_manager: *mut IOSCallManager) -> Result<*mut c_void> {
    info!("get_active_connection():");

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    let connection = call_manager.active_connection()?;
    let app_connection = connection.app_connection()?;

    Ok(app_connection.object)
}

/// CMI request for the active CallContext object
pub fn get_active_call_context(call_manager: *mut IOSCallManager) -> Result<*mut c_void> {
    info!("get_active_call_context():");

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    let call = call_manager.active_call()?;
    let app_call_context = call.call_context()?;

    Ok(app_call_context.object)
}

/// CMI request to set the video status
pub fn set_video_enable(call_manager: *mut IOSCallManager, enable: bool) -> Result<()> {
    info!("set_video_enable():");

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    let mut active_connection = call_manager.active_connection()?;
    active_connection.inject_send_sender_status_via_data_channel(enable)
}

/// Request to update the bandwidth mode on the direct connection
pub fn update_bandwidth_mode(
    call_manager: *mut IOSCallManager,
    bandwidth_mode: BandwidthMode,
) -> Result<()> {
    info!("update_bandwidth_mode():");

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    let mut active_connection = call_manager.active_connection()?;
    active_connection.inject_update_bandwidth_mode(bandwidth_mode)
}

/// CMI request to drop the active call
pub fn drop_call(call_manager: *mut IOSCallManager, call_id: u64) -> Result<()> {
    let call_id = CallId::from(call_id);

    info!("drop_call(): {}", call_id);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.drop_call(call_id)
}

/// CMI request to reset the Call Manager
pub fn reset(call_manager: *mut IOSCallManager) -> Result<()> {
    info!("reset():");

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.reset()
}

/// CMI request to close down the Call Manager.
///
/// This is a blocking call.
pub fn close(call_manager: *mut IOSCallManager) -> Result<()> {
    info!("close():");

    // Convert the raw pointer back into a Box and let it go out of
    // scope when this function exits.
    let mut call_manager = unsafe { ptr_as_box(call_manager)? };
    call_manager.close()
}

// Group Calls

pub fn peek_group_call(
    call_manager: *mut IOSCallManager,
    request_id: u32,
    sfu_url: String,
    membership_proof: Vec<u8>,
    group_members: Vec<group_call::GroupMemberInfo>,
) -> Result<()> {
    info!("peek_group_call(): id: {}", request_id);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.peek_group_call(request_id, sfu_url, membership_proof, group_members);
    Ok(())
}

pub fn create_group_call_client(
    call_manager: *mut IOSCallManager,
    group_id: group_call::GroupId,
    sfu_url: String,
    native_audio_track: *const c_void,
    native_video_track: *const c_void,
) -> Result<group_call::ClientId> {
    info!("create_group_call_client():");

    let outgoing_audio_track =
        media::AudioTrack::owned(native_audio_track as *const media::RffiAudioTrack);
    let outgoing_video_track =
        media::VideoTrack::owned(native_video_track as *const media::RffiVideoTrack);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.create_group_call_client(
        group_id,
        sfu_url,
        None,
        outgoing_audio_track,
        outgoing_video_track,
    )
}

pub fn delete_group_call_client(
    call_manager: *mut IOSCallManager,
    client_id: group_call::ClientId,
) -> Result<()> {
    info!("delete_group_call_client(): id: {}", client_id);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.delete_group_call_client(client_id);
    Ok(())
}

pub fn connect(call_manager: *mut IOSCallManager, client_id: group_call::ClientId) -> Result<()> {
    info!("connect(): id: {}", client_id);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.connect(client_id);
    Ok(())
}

pub fn join(call_manager: *mut IOSCallManager, client_id: group_call::ClientId) -> Result<()> {
    info!("join(): id: {}", client_id);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.join(client_id);
    Ok(())
}

pub fn leave(call_manager: *mut IOSCallManager, client_id: group_call::ClientId) -> Result<()> {
    info!("leave(): id: {}", client_id);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.leave(client_id);
    Ok(())
}

pub fn disconnect(
    call_manager: *mut IOSCallManager,
    client_id: group_call::ClientId,
) -> Result<()> {
    info!("disconnect(): id: {}", client_id);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.disconnect(client_id);
    Ok(())
}

pub fn set_outgoing_audio_muted(
    call_manager: *mut IOSCallManager,
    client_id: group_call::ClientId,
    muted: bool,
) -> Result<()> {
    info!("set_outgoing_audio_muted(): id: {}", client_id);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.set_outgoing_audio_muted(client_id, muted);
    Ok(())
}

pub fn set_outgoing_video_muted(
    call_manager: *mut IOSCallManager,
    client_id: group_call::ClientId,
    muted: bool,
) -> Result<()> {
    info!("set_outgoing_video_muted(): id: {}", client_id);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.set_outgoing_video_muted(client_id, muted);
    Ok(())
}

pub fn resend_media_keys(
    call_manager: *mut IOSCallManager,
    client_id: group_call::ClientId,
) -> Result<()> {
    info!("resend_media_keys(): id: {}", client_id);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.resend_media_keys(client_id);
    Ok(())
}

pub fn set_bandwidth_mode(
    call_manager: *mut IOSCallManager,
    client_id: group_call::ClientId,
    bandwidth_mode: BandwidthMode,
) -> Result<()> {
    info!("set_bandwidth_mode(): id: {}", client_id);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.set_bandwidth_mode(client_id, bandwidth_mode);
    Ok(())
}

pub fn request_video(
    call_manager: *mut IOSCallManager,
    client_id: group_call::ClientId,
    rendered_resolutions: Vec<group_call::VideoRequest>,
) -> Result<()> {
    info!("request_video(): id: {}", client_id);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.request_video(client_id, rendered_resolutions);
    Ok(())
}

pub fn set_group_members(
    call_manager: *mut IOSCallManager,
    client_id: group_call::ClientId,
    members: Vec<group_call::GroupMemberInfo>,
) -> Result<()> {
    info!("set_group_members(): id: {}", client_id);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.set_group_members(client_id, members);
    Ok(())
}

pub fn set_membership_proof(
    call_manager: *mut IOSCallManager,
    client_id: group_call::ClientId,
    proof: Vec<u8>,
) -> Result<()> {
    info!("set_group_membership_proof(): id: {}", client_id);

    let call_manager = unsafe { ptr_as_mut(call_manager)? };
    call_manager.set_membership_proof(client_id, proof);
    Ok(())
}
