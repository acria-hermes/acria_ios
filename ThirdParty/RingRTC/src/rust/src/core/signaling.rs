//
// Copyright 2019-2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

use bytes::{Bytes, BytesMut};
use prost::Message as _;
/// The messages we send over the signaling channel to establish a call.
use std::fmt;
use std::time::Duration;

use crate::common::{CallMediaType, DeviceId, FeatureLevel, Result};
use crate::error::RingRtcError;
use crate::protobuf;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Version {
    // The V1 protocol used SDP, DTLS, and SCTP. Removed.
    // The V2 protocol does not use SCTP. It uses RTP data channels.
    // It uses SDP, but embedded in a protobuf.
    V2,
    // Same as V2 but does not use DTLS. It uses a custom
    // Diffie-Hellman exchange to derive SRTP keys.
    V3,
    // Same as V3 except without any SDP.
    V4,
}

impl Version {
    pub fn enable_dtls(self) -> bool {
        match self {
            Self::V2 => true,
            // This disables DTLS
            Self::V3 => false,
            Self::V4 => false,
        }
    }
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let display = match self {
            Self::V2 => "V2".to_string(),
            Self::V3 => "V3".to_string(),
            Self::V4 => "V4".to_string(),
        };
        write!(f, "{}", display)
    }
}

/// An enum representing the different types of signaling messages that
/// can be sent and received.
#[derive(Clone)]
#[allow(clippy::large_enum_variant)]
pub enum Message {
    Offer(Offer),
    Answer(Answer),
    Ice(Ice),
    Hangup(Hangup),
    LegacyHangup(Hangup),
    Busy,
}

impl Message {
    pub fn typ(&self) -> MessageType {
        match self {
            Self::Offer(_) => MessageType::Offer,
            Self::Answer(_) => MessageType::Answer,
            Self::Ice(_) => MessageType::Ice,
            Self::Hangup(_) => MessageType::Hangup,
            Self::LegacyHangup(_) => MessageType::Hangup,
            Self::Busy => MessageType::Busy,
        }
    }
}

impl fmt::Display for Message {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let display = match self {
            Self::Offer(offer) => format!("Offer({:?}, ...)", offer.call_media_type),
            Self::Answer(_) => "Answer(...)".to_string(),
            Self::Ice(_) => "Ice(...)".to_string(),
            Self::Hangup(hangup) => format!("Hangup({:?})", hangup),
            Self::LegacyHangup(hangup) => format!("LegacyHangup({:?})", hangup),
            Self::Busy => "Busy".to_string(),
        };
        write!(f, "({})", display)
    }
}

impl fmt::Debug for Message {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self)
    }
}

// It's convenient to be able to now the type of a message without having
// an entire message, so we have the related MessageType enum
#[repr(i32)]
#[derive(Debug, PartialEq)]
pub enum MessageType {
    Offer,
    Answer,
    Ice,
    Hangup,
    Busy,
    MediaKey,
}

/// The caller sends this to several callees to initiate the call.
#[derive(Clone)]
pub struct Offer {
    pub call_media_type: CallMediaType,
    pub opaque:          Vec<u8>,
    // We cache a deserialized opaque value to avoid deserializing it repeatedly.
    proto:               protobuf::signaling::Offer,
}

impl Offer {
    pub fn new(call_media_type: CallMediaType, opaque: Vec<u8>) -> Result<Self> {
        let proto = Self::deserialize_opaque(&opaque)?;
        Ok(Self {
            call_media_type,
            opaque,
            proto,
        })
    }

    fn deserialize_opaque(opaque: &[u8]) -> Result<protobuf::signaling::Offer> {
        Ok(protobuf::signaling::Offer::decode(Bytes::from(
            opaque.to_owned(),
        ))?)
    }

    pub fn latest_version(&self) -> Version {
        match self {
            Self {
                proto: protobuf::signaling::Offer { v4: Some(_), .. },
                ..
            } => Version::V4,
            Self {
                proto:
                    protobuf::signaling::Offer {
                        v3_or_v2:
                            Some(protobuf::signaling::ConnectionParametersV3OrV2 {
                                public_key: Some(_),
                                ..
                            }),
                        ..
                    },
                ..
            } => Version::V3,
            _ => Version::V2,
        }
    }

    // V4 == V3 + non-SDP; V3 == V2 + public key
    pub fn from_v4(
        call_media_type: CallMediaType,
        v4: protobuf::signaling::ConnectionParametersV4,
    ) -> Result<Self> {
        let proto = protobuf::signaling::Offer {
            v4: Some(v4),
            ..Default::default()
        };

        let mut opaque = BytesMut::with_capacity(proto.encoded_len());
        proto.encode(&mut opaque)?;

        Self::new(call_media_type, opaque.to_vec())
    }

    // V4 == V3 w/o SDP; V3 == V2 + public key
    pub fn from_v4_and_v3_and_v2(
        call_media_type: CallMediaType,
        public_key: Vec<u8>,
        v4: Option<protobuf::signaling::ConnectionParametersV4>,
        v3_or_v2_sdp: String,
    ) -> Result<Self> {
        let offer_proto_v3_or_v2 = protobuf::signaling::ConnectionParametersV3OrV2 {
            public_key: Some(public_key),
            sdp:        Some(v3_or_v2_sdp),
        };
        let offer_proto = protobuf::signaling::Offer {
            v3_or_v2: Some(offer_proto_v3_or_v2),
            v4,
        };

        let mut opaque = BytesMut::with_capacity(offer_proto.encoded_len());
        offer_proto.encode(&mut opaque)?;

        // Once SDP is gone, pass in the proto rather than deserializing it here.
        Self::new(call_media_type, opaque.to_vec())
    }

    // V4 == V3 + non-SDP
    pub fn to_v4(&self) -> Option<protobuf::signaling::ConnectionParametersV4> {
        match self {
            Self {
                proto: protobuf::signaling::Offer { v4: Some(v4), .. },
                ..
            } => Some(v4.clone()),
            _ => None,
        }
    }

    pub fn to_v3_or_v2_sdp(&self) -> Result<String> {
        match self {
            // Prefer opaque/proto over SDP
            Self {
                proto:
                    protobuf::signaling::Offer {
                        v3_or_v2:
                            Some(protobuf::signaling::ConnectionParametersV3OrV2 {
                                sdp: Some(v3_or_v2_sdp),
                                ..
                            }),
                        ..
                    },
                ..
            } => Ok(v3_or_v2_sdp.clone()),
            _ => Err(RingRtcError::UnknownSignaledProtocolVersion.into()),
        }
    }

    // First return value means "is_v3_or_v2"
    // V3 == V2 + public_key
    pub fn to_v3_or_v2_params(&self) -> Result<(String, Option<Vec<u8>>)> {
        match self {
            // Prefer opaque over SDP
            Self {
                proto:
                    protobuf::signaling::Offer {
                        v3_or_v2:
                            Some(protobuf::signaling::ConnectionParametersV3OrV2 {
                                sdp: Some(v3_or_v2_sdp),
                                public_key,
                            }),
                        ..
                    },
                ..
            } => Ok((v3_or_v2_sdp.clone(), public_key.clone())),
            _ => Err(RingRtcError::UnknownSignaledProtocolVersion.into()),
        }
    }

    pub fn to_info_string(&self) -> String {
        format!(
            "opaque.len={}\tproto.version={}\ttype={}",
            self.opaque.len(),
            self.latest_version(),
            self.call_media_type
        )
    }
}

/// The callee sends this in response to an answer to setup
/// the call.
#[derive(Clone)]
pub struct Answer {
    pub opaque: Vec<u8>,
    // We cache a deserialized opaque value to avoid deserializing it repeatedly.
    proto:      protobuf::signaling::Answer,
}

impl Answer {
    pub fn new(opaque: Vec<u8>) -> Result<Self> {
        let proto = Self::deserialize_opaque(&opaque)?;
        Ok(Self { opaque, proto })
    }

    fn deserialize_opaque(opaque: &[u8]) -> Result<protobuf::signaling::Answer> {
        Ok(protobuf::signaling::Answer::decode(Bytes::from(
            opaque.to_owned(),
        ))?)
    }

    pub fn latest_version(&self) -> Version {
        match self {
            Self {
                proto: protobuf::signaling::Answer { v4: Some(_), .. },
                ..
            } => Version::V4,
            Self {
                proto:
                    protobuf::signaling::Answer {
                        v3_or_v2:
                            Some(protobuf::signaling::ConnectionParametersV3OrV2 {
                                public_key: Some(_),
                                ..
                            }),
                        ..
                    },
                ..
            } => Version::V3,
            _ => Version::V2,
        }
    }

    // V4 == V3 + non-SDP; V3 == V2 + public key
    pub fn from_v4(v4: protobuf::signaling::ConnectionParametersV4) -> Result<Self> {
        let proto = protobuf::signaling::Answer {
            v4: Some(v4),
            ..Default::default()
        };

        let mut opaque = BytesMut::with_capacity(proto.encoded_len());
        proto.encode(&mut opaque)?;

        Self::new(opaque.to_vec())
    }

    // V3 == V2 + public key
    pub fn from_v3_and_v2_sdp(public_key: Vec<u8>, v3_and_v2_sdp: String) -> Result<Self> {
        let answer_proto_v3_or_v2 = protobuf::signaling::ConnectionParametersV3OrV2 {
            public_key: Some(public_key),
            sdp:        Some(v3_and_v2_sdp),
        };
        let answer_proto = protobuf::signaling::Answer {
            v3_or_v2: Some(answer_proto_v3_or_v2),
            ..Default::default()
        };

        let mut opaque = BytesMut::with_capacity(answer_proto.encoded_len());
        answer_proto.encode(&mut opaque)?;

        // Once SDP is gone, pass in the proto rather than deserializing it here.
        Self::new(opaque.to_vec())
    }

    // V4 == V3 + non-SDP; V3 == V2 + public key
    pub fn to_v4(&self) -> Option<protobuf::signaling::ConnectionParametersV4> {
        match self {
            // Prefer opaque over SDP
            Self {
                proto: protobuf::signaling::Answer { v4: Some(v4), .. },
                ..
            } => Some(v4.clone()),
            _ => None,
        }
    }

    // V3 == V2 + public_key
    pub fn to_v3_or_v2_params(&self) -> Result<(String, Option<Vec<u8>>)> {
        match self {
            // Prefer opaque over SDP
            Self {
                proto:
                    protobuf::signaling::Answer {
                        v3_or_v2:
                            Some(protobuf::signaling::ConnectionParametersV3OrV2 {
                                sdp: Some(v3_or_v2_sdp),
                                public_key,
                            }),
                        ..
                    },
                ..
            } => Ok((v3_or_v2_sdp.clone(), public_key.clone())),
            _ => Err(RingRtcError::UnknownSignaledProtocolVersion.into()),
        }
    }

    pub fn to_info_string(&self) -> String {
        format!(
            "opaque.len={}\tproto.version={}",
            self.opaque.len(),
            self.latest_version()
        )
    }
}

/// Each side can send these at any time after the offer and answer
/// are sent.
#[derive(Clone)]
pub struct Ice {
    pub candidates_added: Vec<IceCandidate>,
}

/// Each side sends these to setup an ICE connection
#[derive(Clone)]
pub struct IceCandidate {
    pub opaque: Vec<u8>,
}

impl IceCandidate {
    pub fn new(opaque: Vec<u8>) -> Self {
        Self { opaque }
    }

    // ICE candidates are the same for V2 and V3 and V4.
    pub fn from_v3_and_v2_sdp(sdp: String) -> Result<Self> {
        let ice_candidate_proto_v3_or_v2 =
            protobuf::signaling::IceCandidateV3OrV2 { sdp: Some(sdp) };
        let ice_candidate_proto = protobuf::signaling::IceCandidate {
            v3_or_v2: Some(ice_candidate_proto_v3_or_v2),
        };

        let mut opaque = BytesMut::with_capacity(ice_candidate_proto.encoded_len());
        ice_candidate_proto.encode(&mut opaque)?;

        Ok(Self::new(opaque.to_vec()))
    }

    // ICE candidates are the same for V2 and V3 and V4.
    pub fn to_v3_and_v2_sdp(&self) -> Result<String> {
        match protobuf::signaling::IceCandidate::decode(Bytes::from(self.opaque.clone()))? {
            protobuf::signaling::IceCandidate {
                v3_or_v2:
                    Some(protobuf::signaling::IceCandidateV3OrV2 {
                        sdp: Some(v3_or_v2_sdp),
                    }),
            } => Ok(v3_or_v2_sdp),
            _ => Err(RingRtcError::UnknownSignaledProtocolVersion.into()),
        }
    }

    pub fn to_info_string(&self) -> String {
        format!("opaque.len={}", self.opaque.len())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Hangup {
    Normal, // on this device
    AcceptedOnAnotherDevice(DeviceId),
    DeclinedOnAnotherDevice(DeviceId),
    BusyOnAnotherDevice(DeviceId),
    // If you want to express that you NeedPermission on your device,
    // You can either fill it in or with your own device_id.
    NeedPermission(Option<DeviceId>),
}

impl Hangup {
    pub fn to_type_and_device_id(&self) -> (HangupType, Option<DeviceId>) {
        match self {
            Self::Normal => (HangupType::Normal, None),
            Self::AcceptedOnAnotherDevice(other_device_id) => {
                (HangupType::AcceptedOnAnotherDevice, Some(*other_device_id))
            }
            Self::DeclinedOnAnotherDevice(other_device_id) => {
                (HangupType::DeclinedOnAnotherDevice, Some(*other_device_id))
            }
            Self::BusyOnAnotherDevice(other_device_id) => {
                (HangupType::BusyOnAnotherDevice, Some(*other_device_id))
            }
            Self::NeedPermission(other_device_id) => (HangupType::NeedPermission, *other_device_id),
        }
    }

    // For Normal, device_id is ignored
    // For NeedPermission, we can't express an unset DeviceId because the Android and iOS apps
    // give us DeviceIds of 0 rather than None when receiving, so we just assume it's set.
    // But since our receive logic doesn't care if it's 0 or None or anything else
    // for an outgoing call, that's fine.
    pub fn from_type_and_device_id(typ: HangupType, device_id: DeviceId) -> Self {
        match typ {
            HangupType::Normal => Self::Normal,
            HangupType::AcceptedOnAnotherDevice => Self::AcceptedOnAnotherDevice(device_id),
            HangupType::DeclinedOnAnotherDevice => Self::DeclinedOnAnotherDevice(device_id),
            HangupType::BusyOnAnotherDevice => Self::BusyOnAnotherDevice(device_id),
            HangupType::NeedPermission => Self::NeedPermission(Some(device_id)),
        }
    }
}

impl fmt::Display for Hangup {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let (typ, device_id) = self.to_type_and_device_id();
        match device_id {
            Some(device_id) => write!(f, "{:?}/{}", typ, device_id),
            None => write!(f, "{:?}/None", typ),
        }
    }
}

// It's convenient to be able to now the type of a hangup without having
// an entire message (such as with FFI), so we have the related HangupType.
// For convenience, we make this match the protobufs
#[repr(i32)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HangupType {
    // On this device
    Normal                  = 0,
    AcceptedOnAnotherDevice = 1,
    DeclinedOnAnotherDevice = 2,
    BusyOnAnotherDevice     = 3,
    // On either another device or this device
    NeedPermission          = 4,
}

impl HangupType {
    pub fn from_i32(value: i32) -> Option<Self> {
        match value {
            0 => Some(HangupType::Normal),
            1 => Some(HangupType::AcceptedOnAnotherDevice),
            2 => Some(HangupType::DeclinedOnAnotherDevice),
            3 => Some(HangupType::BusyOnAnotherDevice),
            4 => Some(HangupType::NeedPermission),
            _ => None,
        }
    }
}

/// An Answer with extra info specific to sending
/// Answers are always sent to one device, never broadcast
pub struct SendAnswer {
    pub answer:             Answer,
    pub receiver_device_id: DeviceId,
}

/// An ICE message with extra info specific to sending
/// ICE messages can either target a particular device (callee only)
/// or broadcast (caller only).
pub struct SendIce {
    pub ice:                Ice,
    pub receiver_device_id: Option<DeviceId>,
}

/// A hangup message with extra info specific to sending
/// Hangup messages are always broadcast to all devices.
pub struct SendHangup {
    pub hangup:     Hangup,
    pub use_legacy: bool,
}

/// An Offer with extra info specific to receiving
pub struct ReceivedOffer {
    pub offer:                       Offer,
    /// The approximate age of the offer
    pub age:                         Duration,
    pub sender_device_id:            DeviceId,
    /// The feature level supported by the sender device
    pub sender_device_feature_level: FeatureLevel,
    pub receiver_device_id:          DeviceId,
    /// If true, the receiver (local) device is the primary device, otherwise a linked device
    pub receiver_device_is_primary:  bool,
    pub sender_identity_key:         Vec<u8>,
    pub receiver_identity_key:       Vec<u8>,
}

/// An Answer with extra info specific to receiving
pub struct ReceivedAnswer {
    pub answer:                      Answer,
    pub sender_device_id:            DeviceId,
    /// The feature level supported by the sender device
    pub sender_device_feature_level: FeatureLevel,
    pub sender_identity_key:         Vec<u8>,
    pub receiver_identity_key:       Vec<u8>,
}

/// An Ice message with extra info specific to receiving
pub struct ReceivedIce {
    pub ice:              Ice,
    pub sender_device_id: DeviceId,
}

/// A Hangup message with extra info specific to receiving
#[derive(Clone, Copy, Debug)]
pub struct ReceivedHangup {
    pub hangup:           Hangup,
    pub sender_device_id: DeviceId,
}

/// A Busy message with extra info specific to receiving
pub struct ReceivedBusy {
    pub sender_device_id: DeviceId,
}
