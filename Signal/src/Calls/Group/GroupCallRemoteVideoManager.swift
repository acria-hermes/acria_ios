//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation
import SignalRingRTC

class GroupCallRemoteVideoManager {
    private var currentGroupCall: GroupCall? {
        guard let call = AppEnvironment.shared.callService.currentCall, call.isGroupCall else { return nil }
        return call.groupCall
    }

    // MARK: - Remote Video Views
    private var videoViews = [UInt32: [GroupCallRemoteMemberView.Mode: GroupCallRemoteVideoView]]()

    func remoteVideoView(for device: RemoteDeviceState, mode: GroupCallRemoteMemberView.Mode) -> GroupCallRemoteVideoView {
        AssertIsOnMainThread()

        var currentVideoViewsDevice = videoViews[device.demuxId] ?? [:]

        if let current = currentVideoViewsDevice[mode] { return current }

        let videoView = GroupCallRemoteVideoView(demuxId: device.demuxId)
        videoView.sizeDelegate = self
        videoView.isGroupCall = true

        currentVideoViewsDevice[mode] = videoView
        videoViews[device.demuxId] = currentVideoViewsDevice

        return videoView
    }

    private func destroyRemoteVideoView(for demuxId: UInt32) {
        AssertIsOnMainThread()

        videoViews[demuxId]?.forEach { $0.value.removeFromSuperview() }
        videoViews[demuxId] = nil
    }

    private var updateVideoRequestsDebounceTimer: Timer?
    private func updateVideoRequests() {
        updateVideoRequestsDebounceTimer?.invalidate()
        updateVideoRequestsDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false, block: { [weak self] _ in
            AssertIsOnMainThread()
            guard let self = self else { return }
            guard let groupCall = self.currentGroupCall else { return }

            let videoRequests: [VideoRequest] = groupCall.remoteDeviceStates.map { demuxId, _ in
                guard let renderingVideoViews = self.videoViews[demuxId]?.values.filter({ $0.isRenderingVideo }),
                      !renderingVideoViews.isEmpty else {
                    return VideoRequest(demuxId: demuxId, width: 0, height: 0, framerate: nil)
                }

                let width = renderingVideoViews.reduce(into: 0, { $0 = max($0, $1.currentSize.width) })
                let height = renderingVideoViews.reduce(into: 0, { $0 = max($0, $1.currentSize.height) })

                return VideoRequest(
                    demuxId: demuxId,
                    width: UInt16(width),
                    height: UInt16(height),
                    framerate: height <= GroupCallVideoOverflow.itemHeight ? 15 : 30
                )
            }

            groupCall.updateVideoRequests(resolutions: videoRequests)
        })
    }
}

extension GroupCallRemoteVideoManager: GroupCallRemoteVideoViewSizeDelegate {
    func groupCallRemoteVideoViewDidChangeSize(remoteVideoView: GroupCallRemoteVideoView) {
        AssertIsOnMainThread()
        updateVideoRequests()
    }

    func groupCallRemoteVideoViewDidChangeSuperview(remoteVideoView: GroupCallRemoteVideoView) {
        AssertIsOnMainThread()
        guard let device = currentGroupCall?.remoteDeviceStates[remoteVideoView.demuxId] else { return }
        remoteVideoView.configure(for: device)
        updateVideoRequests()
    }
}

extension GroupCallRemoteVideoManager: CallServiceObserver {
    func didUpdateCall(from oldValue: SignalCall?, to newValue: SignalCall?) {
        guard oldValue != newValue else { return }
        videoViews.forEach { self.destroyRemoteVideoView(for: $0.key) }
        oldValue?.removeObserver(self)
        newValue?.addObserverAndSyncState(observer: self)
    }
}

extension GroupCallRemoteVideoManager: CallObserver {
    func groupCallRemoteDeviceStatesChanged(_ call: SignalCall) {
        for (demuxId, videoViews) in videoViews {
            guard let device = call.groupCall.remoteDeviceStates[demuxId] else {
                destroyRemoteVideoView(for: demuxId)
                continue
            }
            videoViews.values.forEach { $0.configure(for: device) }
        }
    }

    func groupCallEnded(_ call: SignalCall, reason: GroupCallEndReason) {
        videoViews.keys.forEach { destroyRemoteVideoView(for: $0) }
    }
}

private protocol GroupCallRemoteVideoViewSizeDelegate: class {
    func groupCallRemoteVideoViewDidChangeSize(remoteVideoView: GroupCallRemoteVideoView)
    func groupCallRemoteVideoViewDidChangeSuperview(remoteVideoView: GroupCallRemoteVideoView)
}

class GroupCallRemoteVideoView: UIView {
    fileprivate weak var sizeDelegate: GroupCallRemoteVideoViewSizeDelegate?

    fileprivate private(set) var currentSize: CGSize = .zero {
        didSet {
            guard oldValue != currentSize else { return }
            remoteVideoView.frame = CGRect(origin: .zero, size: currentSize)
            sizeDelegate?.groupCallRemoteVideoViewDidChangeSize(remoteVideoView: self)
        }
    }

    // We cannot subclass this, for some unknown reason WebRTC
    // will not render frames properly if we try to.
    private let remoteVideoView = RemoteVideoView()

    private weak var videoTrack: RTCVideoTrack? {
        didSet {
            guard oldValue != videoTrack else { return }
            oldValue?.remove(remoteVideoView)
            videoTrack?.add(remoteVideoView)
        }
    }

    override var frame: CGRect {
        didSet { currentSize = frame.size }
    }

    override var bounds: CGRect {
        didSet { currentSize = bounds.size }
    }

    override func didMoveToSuperview() {
        sizeDelegate?.groupCallRemoteVideoViewDidChangeSuperview(remoteVideoView: self)
    }

    var isGroupCall: Bool {
        get { remoteVideoView.isGroupCall }
        set { remoteVideoView.isGroupCall = newValue }
    }

    var isRenderingVideo: Bool { videoTrack != nil }

    fileprivate let demuxId: UInt32
    fileprivate init(demuxId: UInt32) {
        self.demuxId = demuxId
        super.init(frame: .zero)
        addSubview(remoteVideoView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit { videoTrack = nil }

    func configure(for device: RemoteDeviceState) {
        guard device.demuxId == demuxId else {
            return owsFailDebug("Tried to configure with incorrect device")
        }

        videoTrack = superview == nil ? nil : device.videoTrack
    }
}
