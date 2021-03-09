//
// Copyright 2019-2021 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import SignalRingRTC.RingRTC
import WebRTC
import SignalCoreKit

protocol CallManagerInterfaceDelegate: class {
    func onStartCall(remote: UnsafeRawPointer, callId: UInt64, isOutgoing: Bool, callMediaType: CallMediaType)
    func onEvent(remote: UnsafeRawPointer, event: CallManagerEvent)
    func onSendOffer(callId: UInt64, remote: UnsafeRawPointer, destinationDeviceId: UInt32?, opaque: Data, callMediaType: CallMediaType)
    func onSendAnswer(callId: UInt64, remote: UnsafeRawPointer, destinationDeviceId: UInt32?, opaque: Data)
    func onSendIceCandidates(callId: UInt64, remote: UnsafeRawPointer, destinationDeviceId: UInt32?, candidates: [Data])
    func onSendHangup(callId: UInt64, remote: UnsafeRawPointer, destinationDeviceId: UInt32?, hangupType: HangupType, deviceId: UInt32, useLegacyHangupMessage: Bool)
    func onSendBusy(callId: UInt64, remote: UnsafeRawPointer, destinationDeviceId: UInt32?)
    func sendCallMessage(recipientUuid: UUID, message: Data)
    func sendHttpRequest(requestId: UInt32, url: String, method: CallManagerHttpMethod, headers: [String: String], body: Data?)
    func onCreateConnection(pcObserver: UnsafeMutableRawPointer?, deviceId: UInt32, appCallContext: CallContext, enableDtls: Bool, enableRtpDataChannel: Bool) -> (connection: Connection, pc: UnsafeMutableRawPointer?)
    func onConnectMedia(remote: UnsafeRawPointer, appCallContext: CallContext, stream: RTCMediaStream)
    func onCompareRemotes(remote1: UnsafeRawPointer, remote2: UnsafeRawPointer) -> Bool
    func onCallConcluded(remote: UnsafeRawPointer)

    // Group Calls

    func handlePeekResponse(requestId: UInt32, peekInfo: PeekInfo)

    func requestMembershipProof(clientId: UInt32)
    func requestGroupMembers(clientId: UInt32)
    func handleConnectionStateChanged(clientId: UInt32, connectionState: ConnectionState)
    func handleJoinStateChanged(clientId: UInt32, joinState: JoinState)
    func handleRemoteDevicesChanged(clientId: UInt32, remoteDeviceStates: [RemoteDeviceState])
    func handleIncomingVideoTrack(clientId: UInt32, remoteDemuxId: UInt32, nativeVideoTrack: UnsafeMutableRawPointer?)
    func handlePeekChanged(clientId: UInt32, peekInfo: PeekInfo)
    func handleEnded(clientId: UInt32, reason: GroupCallEndReason)
}

class CallManagerInterface {

    private weak var callManagerObserverDelegate: CallManagerInterfaceDelegate?

    init(delegate: CallManagerInterfaceDelegate) {
        self.callManagerObserverDelegate = delegate

        Logger.debug("object! CallManagerInterface created... \(ObjectIdentifier(self))")
    }

    deinit {
        Logger.debug("object! CallManagerInterface destroyed. \(ObjectIdentifier(self))")
    }

    // MARK: API Functions

    func getWrapper() -> AppInterface {
        return AppInterface(
            object: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            destroy: callManagerInterfaceDestroy,
            onStartCall: callManagerInterfaceOnStartCall,
            onEvent: callManagerInterfaceOnCallEvent,
            onSendOffer: callManagerInterfaceOnSendOffer,
            onSendAnswer: callManagerInterfaceOnSendAnswer,
            onSendIceCandidates: callManagerInterfaceOnSendIceCandidates,
            onSendHangup: callManagerInterfaceOnSendHangup,
            onSendBusy: callManagerInterfaceOnSendBusy,
            sendCallMessage: callManagerInterfaceSendCallMessage,
            sendHttpRequest: callManagerInterfaceSendHttpRequest,
            onCreateConnectionInterface: callManagerInterfaceOnCreateConnectionInterface,
            onCreateMediaStreamInterface: callManagerInterfaceOnCreateMediaStreamInterface,
            onConnectMedia: callManagerInterfaceOnConnectMedia,
            onCompareRemotes: callManagerInterfaceOnCompareRemotes,
            onCallConcluded: callManagerInterfaceOnCallConcluded,

            // Group Calls

            handlePeekResponse: callManagerInterfaceHandlePeekResponse,

            requestMembershipProof: callManagerInterfaceRequestMembershipProof,
            requestGroupMembers: callManagerInterfaceRequestGroupMembers,
            handleConnectionStateChanged: callManagerInterfaceHandleConnectionStateChanged,
            handleJoinStateChanged: callManagerInterfaceHandleJoinStateChanged,
            handleRemoteDevicesChanged: callManagerInterfaceHandleRemoteDevicesChanged,
            handleIncomingVideoTrack: callManagerInterfaceHandleIncomingVideoTrack,
            handlePeekChanged: callManagerInterfaceHandlePeekChanged,
            handleEnded: callManagerInterfaceHandleEnded
        )
    }

    // MARK: Delegate Handlers

    func onStartCall(remote: UnsafeRawPointer, callId: UInt64, isOutgoing: Bool, callMediaType: CallMediaType) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.onStartCall(remote: remote, callId: callId, isOutgoing: isOutgoing, callMediaType: callMediaType)
    }

    func onEvent(remote: UnsafeRawPointer, event: Int32) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        if let validEvent = CallManagerEvent(rawValue: event) {
            delegate.onEvent(remote: remote, event: validEvent)
        } else {
            owsFailDebug("invalid event: \(event)")
        }
    }

    func onSendOffer(callId: UInt64, remote: UnsafeRawPointer, destinationDeviceId: UInt32?, opaque: Data, callMediaType: CallMediaType) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.onSendOffer(callId: callId, remote: remote, destinationDeviceId: destinationDeviceId, opaque: opaque, callMediaType: callMediaType)
    }

    func onSendAnswer(callId: UInt64, remote: UnsafeRawPointer, destinationDeviceId: UInt32?, opaque: Data) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.onSendAnswer(callId: callId, remote: remote, destinationDeviceId: destinationDeviceId, opaque: opaque)
    }

    func onSendIceCandidates(callId: UInt64, remote: UnsafeRawPointer, destinationDeviceId: UInt32?, candidates: [Data]) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.onSendIceCandidates(callId: callId, remote: remote, destinationDeviceId: destinationDeviceId, candidates: candidates)
    }

    func onSendHangup(callId: UInt64, remote: UnsafeRawPointer, destinationDeviceId: UInt32?, hangupType: HangupType, deviceId: UInt32, useLegacyHangupMessage: Bool) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.onSendHangup(callId: callId, remote: remote, destinationDeviceId: destinationDeviceId, hangupType: hangupType, deviceId: deviceId, useLegacyHangupMessage: useLegacyHangupMessage)
    }

    func onSendBusy(callId: UInt64, remote: UnsafeRawPointer, destinationDeviceId: UInt32?) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.onSendBusy(callId: callId, remote: remote, destinationDeviceId: destinationDeviceId)
    }

    func sendCallMessage(recipientUuid: UUID, message: Data) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.sendCallMessage(recipientUuid: recipientUuid, message: message)
    }

    func sendHttpRequest(requestId: UInt32, url: String, method: CallManagerHttpMethod, headers: [String: String], body: Data?) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.sendHttpRequest(requestId: requestId, url: url, method: method, headers: headers, body: body)
    }

    func onCreateConnection(pcObserver: UnsafeMutableRawPointer?, deviceId: UInt32, appCallContext: CallContext, enableDtls: Bool, enableRtpDataChannel: Bool) -> (connection: Connection, pc: UnsafeMutableRawPointer?)? {
        guard let delegate = self.callManagerObserverDelegate else {
            return nil
        }

        return delegate.onCreateConnection(pcObserver: pcObserver, deviceId: deviceId, appCallContext: appCallContext, enableDtls: enableDtls, enableRtpDataChannel: enableRtpDataChannel)
    }

    func onConnectedMedia(remote: UnsafeRawPointer, appCallContext: CallContext, stream: RTCMediaStream) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.onConnectMedia(remote: remote, appCallContext: appCallContext, stream: stream)
    }

    func onCompareRemotes(remote1: UnsafeRawPointer, remote2: UnsafeRawPointer) -> Bool {
        guard let delegate = self.callManagerObserverDelegate else {
            return false
        }

        return delegate.onCompareRemotes(remote1: remote1, remote2: remote2)
    }

    func onCallConcluded(remote: UnsafeRawPointer) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.onCallConcluded(remote: remote)
    }

    // Group Calls

    func handlePeekResponse(requestId: UInt32, peekInfo: PeekInfo) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.handlePeekResponse(requestId: requestId, peekInfo: peekInfo)
    }

    func requestMembershipProof(clientId: UInt32) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.requestMembershipProof(clientId: clientId)
    }

    func requestGroupMembers(clientId: UInt32) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.requestGroupMembers(clientId: clientId)
    }

    func handleConnectionStateChanged(clientId: UInt32, connectionState: ConnectionState) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.handleConnectionStateChanged(clientId: clientId, connectionState: connectionState)
    }

    func handleJoinStateChanged(clientId: UInt32, joinState: JoinState) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.handleJoinStateChanged(clientId: clientId, joinState: joinState)
    }

    func handleRemoteDevicesChanged(clientId: UInt32, remoteDeviceStates: [RemoteDeviceState]) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.handleRemoteDevicesChanged(clientId: clientId, remoteDeviceStates: remoteDeviceStates)
    }

    func handleIncomingVideoTrack(clientId: UInt32, remoteDemuxId: UInt32, nativeVideoTrack: UnsafeMutableRawPointer?) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.handleIncomingVideoTrack(clientId: clientId, remoteDemuxId: remoteDemuxId, nativeVideoTrack: nativeVideoTrack)
    }

    func handlePeekChanged(clientId: UInt32, peekInfo: PeekInfo) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.handlePeekChanged(clientId: clientId, peekInfo: peekInfo)
    }

    func handleEnded(clientId: UInt32, reason: GroupCallEndReason) {
        guard let delegate = self.callManagerObserverDelegate else {
            return
        }

        delegate.handleEnded(clientId: clientId, reason: reason)
    }
}

func callManagerInterfaceDestroy(object: UnsafeMutableRawPointer?) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }

    _ = Unmanaged<CallManagerInterface>.fromOpaque(object).takeRetainedValue()
    // @note There should not be any retainers left for the object
    // so deinit should be called implicitly.
}

func callManagerInterfaceOnStartCall(object: UnsafeMutableRawPointer?, remote: UnsafeRawPointer?, callId: UInt64, isOutgoing: Bool, mediaType: Int32) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    guard let remote = remote else {
        owsFailDebug("remote was unexpectedly nil")
        return
    }

    let callMediaType: CallMediaType
    if let validMediaType = CallMediaType(rawValue: mediaType) {
        callMediaType = validMediaType
    } else {
        owsFailDebug("unexpected call media type")
        return
    }

    obj.onStartCall(remote: remote, callId: callId, isOutgoing: isOutgoing, callMediaType: callMediaType)
}

func callManagerInterfaceOnCallEvent(object: UnsafeMutableRawPointer?, remote: UnsafeRawPointer?, event: Int32) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    guard let remote = remote else {
        owsFailDebug("remote was unexpectedly nil")
        return
    }

    obj.onEvent(remote: remote, event: event)
}

func callManagerInterfaceOnSendOffer(object: UnsafeMutableRawPointer?, callId: UInt64, remote: UnsafeRawPointer?, destinationDeviceId: UInt32, broadcast: Bool, opaque: AppByteSlice, mediaType: Int32) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    guard let remote = remote else {
        owsFailDebug("remote was unexpectedly nil")
        return
    }

    // If we will broadcast this message, ignore the deviceId.
    var destinationDeviceId: UInt32? = destinationDeviceId
    if broadcast {
        destinationDeviceId = nil
    }

    guard let opaque = opaque.asData() else {
        owsFailDebug("opaque was unexpectedly nil")
        return
    }

    let callMediaType: CallMediaType
    if let validMediaType = CallMediaType(rawValue: mediaType) {
        callMediaType = validMediaType
    } else {
        owsFailDebug("unexpected call media type")
        return
    }

    obj.onSendOffer(callId: callId, remote: remote, destinationDeviceId: destinationDeviceId, opaque: opaque, callMediaType: callMediaType)
}

func callManagerInterfaceOnSendAnswer(object: UnsafeMutableRawPointer?, callId: UInt64, remote: UnsafeRawPointer?, destinationDeviceId: UInt32, broadcast: Bool, opaque: AppByteSlice) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    guard let remote = remote else {
        owsFailDebug("remote was unexpectedly nil")
        return
    }

    // If we will broadcast this message, ignore the deviceId.
    var destinationDeviceId: UInt32? = destinationDeviceId
    if broadcast {
        destinationDeviceId = nil
    }

    guard let opaque = opaque.asData() else {
        owsFailDebug("opaque was unexpectedly nil")
        return
    }

    obj.onSendAnswer(callId: callId, remote: remote, destinationDeviceId: destinationDeviceId, opaque: opaque)
}

func callManagerInterfaceOnSendIceCandidates(object: UnsafeMutableRawPointer?, callId: UInt64, remote: UnsafeRawPointer?, destinationDeviceId: UInt32, broadcast: Bool, candidates: UnsafePointer<AppIceCandidateArray>?) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    guard let remote = remote else {
        owsFailDebug("remote was unexpectedly nil")
        return
    }

    guard let candidates = candidates else {
        owsFailDebug("candidates was unexpectedly nil")
        return
    }

    let iceCandidates = UnsafePointer<AppIceCandidateArray>(candidates)
    let count = iceCandidates.pointee.count

    var finalCandidates: [Data] = []

    for index in 0..<count {
        guard let iceCandidate = iceCandidates.pointee.candidates[index].asData() else {
            continue
        }

        finalCandidates.append(iceCandidate)
    }

    // If we will broadcast this message, ignore the deviceId.
    var destinationDeviceId: UInt32? = destinationDeviceId
    if broadcast {
        destinationDeviceId = nil
    }

    obj.onSendIceCandidates(callId: callId, remote: remote, destinationDeviceId: destinationDeviceId, candidates: finalCandidates)
}

func callManagerInterfaceOnSendHangup(object: UnsafeMutableRawPointer?, callId: UInt64, remote: UnsafeRawPointer?, destinationDeviceId: UInt32, broadcast: Bool, type: Int32, deviceId: UInt32, useLegacyHangupMessage: Bool) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    guard let remote = remote else {
        owsFailDebug("remote was unexpectedly nil")
        return
    }

    // If we will broadcast this message, ignore the deviceId.
    var destinationDeviceId: UInt32? = destinationDeviceId
    if broadcast {
        destinationDeviceId = nil
    }

    let hangupType: HangupType
    if let validHangupType = HangupType(rawValue: type) {
        hangupType = validHangupType
    } else {
        owsFailDebug("unexpected hangup type")
        return
    }

    obj.onSendHangup(callId: callId, remote: remote, destinationDeviceId: destinationDeviceId, hangupType: hangupType, deviceId: deviceId, useLegacyHangupMessage: useLegacyHangupMessage)
}

func callManagerInterfaceOnSendBusy(object: UnsafeMutableRawPointer?, callId: UInt64, remote: UnsafeRawPointer?, destinationDeviceId: UInt32, broadcast: Bool) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    guard let remote = remote else {
        owsFailDebug("remote was unexpectedly nil")
        return
    }

    // If we will broadcast this message, ignore the deviceId.
    var destinationDeviceId: UInt32? = destinationDeviceId
    if broadcast {
        destinationDeviceId = nil
    }

    obj.onSendBusy(callId: callId, remote: remote, destinationDeviceId: destinationDeviceId)
}

func callManagerInterfaceSendCallMessage(object: UnsafeMutableRawPointer?, recipientUuid: AppByteSlice, message: AppByteSlice) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    guard let recipient = recipientUuid.asData() else {
        return
    }

    guard let message = message.asData() else {
        return
    }

    obj.sendCallMessage(recipientUuid: recipient.uuid, message: message)
}

func callManagerInterfaceSendHttpRequest(object: UnsafeMutableRawPointer?, requestId: UInt32, url: AppByteSlice, method: Int32, headerArray: AppHeaderArray, body: AppByteSlice) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    guard let url = url.asString() else {
        Logger.error("url is not a valid string")
        return
    }

    let httpMethod: CallManagerHttpMethod
    if let validHttpMethod = CallManagerHttpMethod(rawValue: method) {
        httpMethod = validHttpMethod
    } else {
        owsFailDebug("unexpected method")
        return
    }

    var finalHeaders: [String: String] = [:]
    for index in 0..<headerArray.count {
        guard let name = headerArray.headers[index].name.asString() else {
            continue
        }

        finalHeaders[name] = headerArray.headers[index].value.asString()
    }

    obj.sendHttpRequest(requestId: requestId, url: url, method: httpMethod, headers: finalHeaders, body: body.asData())
}

func callManagerInterfaceOnCreateConnectionInterface(object: UnsafeMutableRawPointer?, observer: UnsafeMutableRawPointer?, deviceId: UInt32, context: UnsafeMutableRawPointer?, enableDtls: Bool, enableRtpDataChannel: Bool) -> AppConnectionInterface {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")

        // Swift was problematic to pass back some nullable structure, so we
        // now pass an empty structure back. Check pc for now to validate.
        return AppConnectionInterface(
            object: nil,
            pc: nil,
            destroy: nil)
    }

    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    // @todo Make sure there is a pcObserver.

    guard let callContext = context else {
        owsFailDebug("context was unexpectedly nil")

        // Swift was problematic to pass back some nullable structure, so we
        // now pass an empty structure back. Check pc for now to validate.
        return AppConnectionInterface(
            object: nil,
            pc: nil,
            destroy: nil)
    }

    let appCallContext: CallContext = Unmanaged.fromOpaque(callContext).takeUnretainedValue()

    if let connectionDetails = obj.onCreateConnection(pcObserver: observer, deviceId: deviceId, appCallContext: appCallContext, enableDtls: enableDtls, enableRtpDataChannel: enableRtpDataChannel) {
        return connectionDetails.connection.getWrapper(pc: connectionDetails.pc)
    } else {
        // Swift was problematic to pass back some nullable structure, so we
        // now pass an empty structure back. Check pc for now to validate.
        // @todo Should check object, not pc, for consistency. We will pass valid object if the whole thing is valid...
        return AppConnectionInterface(
            object: nil,
            pc: nil,
            destroy: nil)
    }
}

func callManagerInterfaceOnCreateMediaStreamInterface(object: UnsafeMutableRawPointer?, connection: UnsafeMutableRawPointer?) -> AppMediaStreamInterface {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")

        // Swift was problematic to pass back some nullable structure, so we
        // now pass an empty structure back.
        return AppMediaStreamInterface(
            object: nil,
            destroy: nil,
            createMediaStream: nil)
    }

    let _: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    guard let appConnection = connection else {
        owsFailDebug("appConnection was unexpectedly nil")

        // Swift was problematic to pass back some nullable structure, so we
        // now pass an empty structure back.
        return AppMediaStreamInterface(
            object: nil,
            destroy: nil,
            createMediaStream: nil)
    }

    let connection: Connection = Unmanaged.fromOpaque(appConnection).takeUnretainedValue()

    // For this function, we don't need the Call Manager object to anything, so we
    // will directly create a ConnectionMediaStream object and return it.

    let appMediaStream = ConnectionMediaStream(connection: connection)

    return appMediaStream.getWrapper()
}

func callManagerInterfaceOnConnectMedia(object: UnsafeMutableRawPointer?, remote: UnsafeRawPointer?, context: UnsafeMutableRawPointer?, stream: UnsafeRawPointer?) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    guard let remote = remote else {
        owsFailDebug("remote was unexpectedly nil")
        return
    }

    guard let callContext = context else {
        owsFailDebug("context was unexpectedly nil")
        return
    }

    let appCallContext: CallContext = Unmanaged.fromOpaque(callContext).takeUnretainedValue()

    guard let stream = stream else {
        owsFailDebug("stream was unexpectedly nil")
        return
    }

    let mediaStream: RTCMediaStream = Unmanaged.fromOpaque(stream).takeUnretainedValue()

    obj.onConnectedMedia(remote: remote, appCallContext: appCallContext, stream: mediaStream)
}

func callManagerInterfaceOnCompareRemotes(object: UnsafeMutableRawPointer?, remote1: UnsafeRawPointer?, remote2: UnsafeRawPointer?) -> Bool {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return false
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    guard let remote1 = remote1 else {
        owsFailDebug("remote1 was unexpectedly nil")
        return false
    }

    guard let remote2 = remote2 else {
        owsFailDebug("remote2 was unexpectedly nil")
        return false
    }

    return obj.onCompareRemotes(remote1: remote1, remote2: remote2)
}

func callManagerInterfaceOnCallConcluded(object: UnsafeMutableRawPointer?, remote: UnsafeRawPointer?) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    guard let remote = remote else {
        owsFailDebug("remote was unexpectedly nil")
        return
    }

    obj.onCallConcluded(remote: remote)
}

// Group Calls

func callManagerInterfaceHandlePeekResponse(object: UnsafeMutableRawPointer?, requestId: UInt32, joinedMembers: AppUuidArray, creator: AppByteSlice, eraId: AppByteSlice, maxDevices: AppOptionalUInt32, deviceCount: UInt32) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    var finalJoinedMembers: [UUID] = []

    for index in 0..<joinedMembers.count {
        guard let userId = joinedMembers.uuids[index].asData() else {
            Logger.debug("missing userId")
            continue
        }

        finalJoinedMembers.append(userId.uuid)
    }

    var finalMaxDevices: UInt32?
    if maxDevices.valid {
        finalMaxDevices = maxDevices.value
    }

    let peekInfo = PeekInfo(joinedMembers: finalJoinedMembers, creator: creator.asData()?.uuid, eraId: eraId.asString(), maxDevices: finalMaxDevices, deviceCount: deviceCount)

    obj.handlePeekResponse(requestId: requestId, peekInfo: peekInfo)
}

func callManagerInterfaceRequestMembershipProof(object: UnsafeMutableRawPointer?, clientId: UInt32) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    obj.requestMembershipProof(clientId: clientId)
}

func callManagerInterfaceRequestGroupMembers(object: UnsafeMutableRawPointer?, clientId: UInt32) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    obj.requestGroupMembers(clientId: clientId)
}

func callManagerInterfaceHandleConnectionStateChanged(object: UnsafeMutableRawPointer?, clientId: UInt32, connectionState: Int32) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    let _connectionState: ConnectionState
    if let validState = ConnectionState(rawValue: connectionState) {
        _connectionState = validState
    } else {
        owsFailDebug("unexpected connection state")
        return
    }

    obj.handleConnectionStateChanged(clientId: clientId, connectionState: _connectionState)
}

func callManagerInterfaceHandleJoinStateChanged(object: UnsafeMutableRawPointer?, clientId: UInt32, joinState: Int32) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    let _joinState: JoinState
    if let validState = JoinState(rawValue: joinState) {
        _joinState = validState
    } else {
        owsFailDebug("unexpected join state")
        return
    }

    obj.handleJoinStateChanged(clientId: clientId, joinState: _joinState)
}

func callManagerInterfaceHandleRemoteDevicesChanged(object: UnsafeMutableRawPointer?, clientId: UInt32, remoteDeviceStates: AppRemoteDeviceStateArray) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    var finalRemoteDeviceStates: [RemoteDeviceState] = []

    for index in 0..<remoteDeviceStates.count {
        let remoteDeviceState = remoteDeviceStates.states[index]

        guard let userId = remoteDeviceState.user_id.asData() else {
            Logger.debug("missing userId for demuxId: \(remoteDeviceState.demuxId)")
            continue
        }

        let deviceState = RemoteDeviceState(demuxId: remoteDeviceState.demuxId, userId: userId.uuid, mediaKeysReceived: remoteDeviceState.mediaKeysReceived, addedTime: remoteDeviceState.addedTime, speakerTime: remoteDeviceState.speakerTime)

        if remoteDeviceState.audioMuted.valid {
            deviceState.audioMuted = remoteDeviceState.audioMuted.value
        }

        if remoteDeviceState.videoMuted.valid {
            deviceState.videoMuted = remoteDeviceState.videoMuted.value
        }

        finalRemoteDeviceStates.append(deviceState)
    }

    obj.handleRemoteDevicesChanged(clientId: clientId, remoteDeviceStates: finalRemoteDeviceStates)
}

func callManagerInterfaceHandleIncomingVideoTrack(object: UnsafeMutableRawPointer?, clientId: UInt32, remoteDemuxId: UInt32, nativeVideoTrack: UnsafeMutableRawPointer?) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    obj.handleIncomingVideoTrack(clientId: clientId, remoteDemuxId: remoteDemuxId, nativeVideoTrack: nativeVideoTrack)
}

func callManagerInterfaceHandlePeekChanged(object: UnsafeMutableRawPointer?, clientId: UInt32, joinedMembers: AppUuidArray, creator: AppByteSlice, eraId: AppByteSlice, maxDevices: AppOptionalUInt32, deviceCount: UInt32) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    var finalJoinedMembers: [UUID] = []

    for index in 0..<joinedMembers.count {
        guard let userId = joinedMembers.uuids[index].asData() else {
            Logger.debug("missing userId")
            continue
        }

        finalJoinedMembers.append(userId.uuid)
    }

    var finalMaxDevices: UInt32?
    if maxDevices.valid {
        finalMaxDevices = maxDevices.value
    }

    let peekInfo = PeekInfo(joinedMembers: finalJoinedMembers, creator: creator.asData()?.uuid, eraId: eraId.asString(), maxDevices: finalMaxDevices, deviceCount: deviceCount)

    obj.handlePeekChanged(clientId: clientId, peekInfo: peekInfo)
}

func callManagerInterfaceHandleEnded(object: UnsafeMutableRawPointer?, clientId: UInt32, reason: Int32) {
    guard let object = object else {
        owsFailDebug("object was unexpectedly nil")
        return
    }
    let obj: CallManagerInterface = Unmanaged.fromOpaque(object).takeUnretainedValue()

    let _reason: GroupCallEndReason
    if let validReason = GroupCallEndReason(rawValue: reason) {
        _reason = validReason
    } else {
        owsFailDebug("unexpected end reason")
        return
    }

    obj.handleEnded(clientId: clientId, reason: _reason)
}
