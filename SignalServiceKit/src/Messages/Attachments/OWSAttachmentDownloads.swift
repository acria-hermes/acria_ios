//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit

@objc
public class OWSAttachmentDownloads: NSObject {

    // MARK: - Dependencies

    private class var signalService: OWSSignalService {
        return .shared()
    }

    private class var databaseStorage: SDSDatabaseStorage {
        return SDSDatabaseStorage.shared
    }

    private class var profileManager: ProfileManagerProtocol {
        return SSKEnvironment.shared.profileManager
    }

    private class var reachabilityManager: SSKReachabilityManager {
        SSKEnvironment.shared.reachabilityManager
    }

    private class var networkManager: TSNetworkManager {
        return SSKEnvironment.shared.networkManager
    }

    // MARK: -

    public typealias AttachmentId = String

    private enum JobType {
        case messageAttachment(attachmentId: AttachmentId, message: TSMessage)
        case headlessAttachment(attachmentPointer: TSAttachmentPointer)

        var attachmentId: AttachmentId {
            switch self {
            case .messageAttachment(let attachmentId, _):
                return attachmentId
            case .headlessAttachment(let attachmentPointer):
                return attachmentPointer.uniqueId
            }
        }

        var message: TSMessage? {
            switch self {
            case .messageAttachment(_, let message):
                return message
            case .headlessAttachment:
                return nil
            }
        }
    }

    private struct JobRequest {
        let jobType: JobType
        let category: AttachmentCategory

        var attachmentId: AttachmentId { jobType.attachmentId }
        var message: TSMessage? { jobType.message }

        func loadLatestAttachment(transaction: SDSAnyReadTransaction) -> TSAttachment? {
            return TSAttachment.anyFetch(uniqueId: attachmentId, transaction: transaction)
        }
    }

    private class Job {
        let jobRequest: JobRequest
        var jobType: JobType { jobRequest.jobType }
        let downloadBehavior: AttachmentDownloadBehavior

        let promise: Promise<TSAttachmentStream>
        let resolver: Resolver<TSAttachmentStream>

        var progress: CGFloat = 0
        var attachmentId: AttachmentId { jobType.attachmentId }
        var message: TSMessage? { jobType.message }
        var category: AttachmentCategory { jobRequest.category }

        init(jobRequest: JobRequest, downloadBehavior: AttachmentDownloadBehavior) {

            self.jobRequest = jobRequest
            self.downloadBehavior = downloadBehavior

            let (promise, resolver) = Promise<TSAttachmentStream>.pending()
            self.promise = promise
            self.resolver = resolver
        }

        func loadLatestAttachment(transaction: SDSAnyReadTransaction) -> TSAttachment? {
            jobRequest.loadLatestAttachment(transaction: transaction)
        }
    }

    private static let unfairLock = UnfairLock()
    // This property should only be accessed with unfairLock.
    private var activeJobMap = [AttachmentId: Job]()
    // This property should only be accessed with unfairLock.
    private var jobQueue = [Job]()
    // This property should only be accessed with unfairLock.
    private var completeAttachmentMap = Set<AttachmentId>()

    @objc
    public override init() {
        super.init()

        SwiftSingletons.register(self)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(profileWhitelistDidChange(notification:)),
                                               name: .profileWhitelistDidChange,
                                               object: nil)
    }

    @objc
    func profileWhitelistDidChange(notification: Notification) {
        AssertIsOnMainThread()

        // If a thread was newly whitelisted, try and start any
        // downloads that were pending on a message request.
        Self.databaseStorage.read { transaction in
            guard let whitelistedThread = ({ () -> TSThread? in
                if let address = notification.userInfo?[kNSNotificationKey_ProfileAddress] as? SignalServiceAddress,
                   address.isValid,
                   Self.profileManager.isUser(inProfileWhitelist: address, transaction: transaction) {
                    return TSContactThread.getWithContactAddress(address, transaction: transaction)
                }
                if let groupId = notification.userInfo?[kNSNotificationKey_ProfileGroupId] as? Data,
                   Self.profileManager.isGroupId(inProfileWhitelist: groupId, transaction: transaction) {
                    return TSGroupThread.fetch(groupId: groupId, transaction: transaction)
                }
                return nil
            }()) else {
                return
            }
            self.enqueueDownloadOfAllAttachments(forThread: whitelistedThread,
                                                 transaction: transaction)
        }
    }

    // MARK: -

    public func downloadProgress(forAttachmentId attachmentId: AttachmentId) -> CGFloat? {
        Self.unfairLock.withLock {
            if let job = activeJobMap[attachmentId] {
                return job.progress
            }
            if completeAttachmentMap.contains(attachmentId) {
                return 1.0
            }
            return nil
        }
    }

    // MARK: -

    private func enqueueJob(job: Job) {
        Self.unfairLock.withLock {
            jobQueue.append(job)
        }

        tryToStartNextDownload()
    }

    private func dequeueNextJob() -> Job? {
        Self.unfairLock.withLock {
            let kMaxSimultaneousDownloads = 4
            guard activeJobMap.count < kMaxSimultaneousDownloads else {
                return nil
            }
            guard let job = jobQueue.first else {
                return nil
            }
            jobQueue.remove(at: 0)
            guard activeJobMap[job.attachmentId] == nil else {
                // Ensure we only have one download in flight at a time for a given attachment.
                Logger.warn("Ignoring duplicate download.")
                return nil
            }
            activeJobMap[job.attachmentId] = job
            return job
        }
    }

    private func markJobComplete(_ job: Job, isAttachmentDownloaded: Bool) {
        Self.unfairLock.withLock {
            let attachmentId = job.attachmentId

            owsAssertDebug(activeJobMap[attachmentId] != nil)
            activeJobMap[attachmentId] = nil

            cancellationRequestMap[attachmentId] = nil

            if isAttachmentDownloaded {
                owsAssertDebug(!completeAttachmentMap.contains(attachmentId))
                completeAttachmentMap.insert(attachmentId)
            }
        }
        tryToStartNextDownload()
    }

    private func tryToStartNextDownload() {
        Self.serialQueue.async {
            guard let job = self.dequeueNextJob() else {
                return
            }

            guard let attachmentPointer = self.prepareDownload(job: job) else {
                // Abort.
                self.markJobComplete(job, isAttachmentDownloaded: false)
                return
            }

            firstly { () -> Promise<TSAttachmentStream> in
                self.retrieveAttachment(job: job, attachmentPointer: attachmentPointer)
            }.done(on: Self.serialQueue) { (attachmentStream: TSAttachmentStream) in
                self.downloadDidSucceed(attachmentStream: attachmentStream, job: job)
            }.catch(on: Self.serialQueue) { (error: Error) in
                self.downloadDidFail(error: error, job: job)
            }
        }
    }

    private func prepareDownload(job: Job) -> TSAttachmentPointer? {
        Self.databaseStorage.write { transaction in
            // Fetch latest to ensure we don't overwrite an attachment stream, resurrect an attachment, etc.
            guard let attachment = job.loadLatestAttachment(transaction: transaction) else {
                // This isn't necessarily a bug.  For example:
                //
                // * Receive an incoming message with an attachment.
                // * Kick off download of that attachment.
                // * Receive read receipt for that message, causing it to be disappeared immediately.
                // * Try to download that attachment - but it's missing.
                Logger.warn("Missing attachment: \(job.category).")
                return nil
            }
            guard let attachmentPointer = attachment as? TSAttachmentPointer else {
                // This isn't necessarily a bug.
                //
                // * An attachment may have been re-enqueued for download while it was already being downloaded.
                owsFailDebug("Attachment already downloaded: \(job.category).")

                Self.unfairLock.withLock {
                    owsAssertDebug(!self.completeAttachmentMap.contains(job.attachmentId))
                    self.completeAttachmentMap.insert(job.attachmentId)
                }

                return nil
            }

            switch job.jobType {
            case .messageAttachment(_, let message):
                if DebugFlags.forceAttachmentDownloadFailures.get() {
                    Logger.info("Skipping media download for thread due to debug settings: \(job.category).")
                    attachmentPointer.updateAttachmentPointerState(from: .enqueued,
                                                                   to: .failed,
                                                                   transaction: transaction)
                    return nil
                }

                if self.isDownloadBlockedByActiveCall(job: job) {
                    Logger.info("Skipping media download due to active call: \(job.category).")
                    attachmentPointer.updateAttachmentPointerState(from: .enqueued,
                                                                   to: .pendingManualDownload,
                                                                   transaction: transaction)
                    return nil
                }
                if self.isDownloadBlockedByPendingMessageRequest(job: job,
                                                                 attachmentPointer: attachmentPointer,
                                                                 message: message,
                                                                 transaction: transaction) {
                    Logger.info("Skipping media download for thread with pending message request: \(job.category).")
                    attachmentPointer.updateAttachmentPointerState(from: .enqueued,
                                                                   to: .pendingMessageRequest,
                                                                   transaction: transaction)
                    return nil
                }
                if self.isDownloadBlockedByAutoDownloadSettingsSettings(job: job,
                                                                        attachmentPointer: attachmentPointer,
                                                                        transaction: transaction) {
                    Logger.info("Skipping media download for thread due to auto-download settings: \(job.category).")
                    attachmentPointer.updateAttachmentPointerState(from: .enqueued,
                                                                   to: .pendingManualDownload,
                                                                   transaction: transaction)
                    return nil
                }
            case .headlessAttachment:
                // We don't need to apply attachment download settings
                // to headless attachments.
                break
            }

            Logger.info("Downloading: \(job.category).")

            attachmentPointer.updateAttachmentPointerState(.downloading, transaction: transaction)

            if let message = job.message {
                Self.reloadAndTouchLatestVersionOfMessage(message, transaction: transaction)
            }
            return attachmentPointer
        }
    }

    private func isDownloadBlockedByActiveCall(job: Job) -> Bool {

        guard !job.downloadBehavior.bypassPendingManualDownload else {
            return false
        }

        switch job.category {
        case .bodyMediaImage, .bodyMediaVideo:
            break
        case .bodyAudioVoiceMemo, .bodyOversizeText:
            return false
        case .bodyAudioOther, .bodyFile:
            break
        case .stickerSmall:
            return false
        case .stickerLarge:
            break
        case .quotedReplyThumbnail, .linkedPreviewThumbnail, .contactShareAvatar:
            return false
        case .other:
            return false
        }

        return CurrentAppContext().hasActiveCall
    }

    private func isDownloadBlockedByPendingMessageRequest(job: Job,
                                                          attachmentPointer: TSAttachmentPointer,
                                                          message: TSMessage,
                                                          transaction: SDSAnyReadTransaction) -> Bool {

        guard !job.downloadBehavior.bypassPendingMessageRequest else {
            return false
        }

        if DebugFlags.forceAttachmentDownloadPendingMessageRequest.get() {
            return true
        }

        let hasPendingMessageRequest: Bool = {
            guard !message.isOutgoing else {
                return false
            }
            let thread = message.thread(transaction: transaction)
            // If the message that created this attachment was the first message in the
            // thread, the thread may not yet be marked visible. In that case, just check
            // if the thread is whitelisted. We know we just received a message.
            if !thread.shouldThreadBeVisible {
                return !Self.profileManager.isThread(inProfileWhitelist: thread,
                                                     transaction: transaction)
            } else {
                return GRDBThreadFinder.hasPendingMessageRequest(thread: thread,
                                                                 transaction: transaction.unwrapGrdbRead)
            }
        }()

        guard attachmentPointer.isVisualMedia,
              hasPendingMessageRequest,
              message.messageSticker == nil,
              !message.isViewOnceMessage else {
            return false
        }
        return true
    }

    private func isDownloadBlockedByAutoDownloadSettingsSettings(job: Job,
                                                                 attachmentPointer: TSAttachmentPointer,
                                                                 transaction: SDSAnyReadTransaction) -> Bool {

        guard !job.downloadBehavior.bypassPendingManualDownload else {
            return false
        }

        if DebugFlags.forceAttachmentDownloadPendingManualDownload.get() {
            return true
        }

        let autoDownloadableMediaTypes = Self.autoDownloadableMediaTypes(transaction: transaction)

        switch job.category {
        case .bodyMediaImage:
            return !autoDownloadableMediaTypes.contains(.photo)
        case .bodyMediaVideo:
            return !autoDownloadableMediaTypes.contains(.video)
        case .bodyAudioVoiceMemo, .bodyOversizeText:
            return false
        case .bodyAudioOther:
            return !autoDownloadableMediaTypes.contains(.audio)
        case .bodyFile:
            return !autoDownloadableMediaTypes.contains(.document)
        case .stickerSmall:
            return false
        case .stickerLarge:
            return autoDownloadableMediaTypes.contains(.photo)
        case .quotedReplyThumbnail, .linkedPreviewThumbnail, .contactShareAvatar:
            return false
        case .other:
            return false
        }
    }

    private func downloadDidSucceed(attachmentStream: TSAttachmentStream,
                                    job: Job) {
        Logger.verbose("Attachment download succeeded.")

        if job.category.isSticker,
           let filePath = attachmentStream.originalFilePath {
            let imageMetadata = NSData.imageMetadata(withPath: filePath, mimeType: nil)
            if imageMetadata.imageFormat != .unknown,
               let mimeTypeFromMetadata = imageMetadata.mimeType {
                attachmentStream.replaceUnsavedContentType(mimeTypeFromMetadata)
            }
        }

        Self.databaseStorage.write { transaction in
            guard let attachmentPointer = job.loadLatestAttachment(transaction: transaction) as? TSAttachmentPointer else {
                Logger.warn("Attachment pointer no longer exists.")
                return
            }
            attachmentPointer.anyRemove(transaction: transaction)
            attachmentStream.anyInsert(transaction: transaction)

            if let message = job.message {
                Self.reloadAndTouchLatestVersionOfMessage(message, transaction: transaction)
            }
        }

        // TODO: Should we fulfill() if the attachmentPointer no longer existed?
        job.resolver.fulfill(attachmentStream)

        markJobComplete(job, isAttachmentDownloaded: true)
    }

    private func downloadDidFail(error: Error, job: Job) {
        Logger.error("Attachment download failed with error: \(error)")

        Self.databaseStorage.write { transaction in
            // Fetch latest to ensure we don't overwrite an attachment stream, resurrect an attachment, etc.
            guard let attachmentPointer = job.loadLatestAttachment(transaction: transaction) as? TSAttachmentPointer else {
                Logger.warn("Attachment pointer no longer exists.")
                return
            }
            switch attachmentPointer.state {
            case .failed, .pendingMessageRequest, .pendingManualDownload:
                owsFailDebug("Unexpected state: \(NSStringForTSAttachmentPointerState(attachmentPointer.state))")
            case .enqueued, .downloading:
                // If the download was cancelled, mark as paused.                
                if case AttachmentDownloadError.cancelled = error {
                    attachmentPointer.updateAttachmentPointerState(.pendingManualDownload, transaction: transaction)
                } else {
                    attachmentPointer.updateAttachmentPointerState(.failed, transaction: transaction)
                }
            @unknown default:
                owsFailDebug("Invalid value.")
            }

            if let message = job.message {
                Self.reloadAndTouchLatestVersionOfMessage(message, transaction: transaction)
            }
        }

        job.resolver.reject(error)

        markJobComplete(job, isAttachmentDownloaded: false)
    }

    private static func reloadAndTouchLatestVersionOfMessage(_ message: TSMessage,
                                                             transaction: SDSAnyWriteTransaction) {
        let messageToNotify: TSMessage
        if message.sortId > 0 {
            messageToNotify = message
        } else {
            // Ensure relevant sortId is loaded for touch to succeed.
            guard let latestMessage = TSMessage.anyFetchMessage(uniqueId: message.uniqueId, transaction: transaction) else {
                // This could be valid but should be very rare.
                owsFailDebug("Message has been deleted.")
                return
            }
            messageToNotify = latestMessage
        }
        // We need to re-index as we may have just downloaded an attachment
        // that affects index content (e.g. oversize text attachment).
        Self.databaseStorage.touch(interaction: messageToNotify, shouldReindex: true, transaction: transaction)
    }

    // MARK: - Cancellation

    // This property should only be accessed with unfairLock.
    private var cancellationRequestMap = [String: Date]()

    public func cancelDownload(attachmentId: AttachmentId) {
        Self.unfairLock.withLock {
            cancellationRequestMap[attachmentId] = Date()
        }
    }

    private func shouldCancelJob(downloadState: DownloadState) -> Bool {
        Self.unfairLock.withLock {
            guard let cancellationDate = cancellationRequestMap[downloadState.job.attachmentId] else {
                return false
            }
            return cancellationDate > downloadState.startDate
        }
    }
}

// MARK: - Settings

@objc
public enum AttachmentDownloadBehavior: UInt, Equatable {
    case `default`
    case bypassPendingMessageRequest
    case bypassPendingManualDownload
    case bypassAll

    public static var defaultValue: MediaBandwidthPreference { .wifiAndCellular }

    public var bypassPendingMessageRequest: Bool {
        switch self {
        case .bypassPendingMessageRequest, .bypassAll:
            return true
        default:
            return false
        }
    }

    public var bypassPendingManualDownload: Bool {
        switch self {
        case .bypassPendingManualDownload, .bypassAll:
            return true
        default:
            return false
        }
    }
}

// MARK: -

public enum MediaBandwidthPreference: UInt, Equatable, CaseIterable {
    case never
    case wifiOnly
    case wifiAndCellular

    public var sortKey: UInt {
        switch self {
        case .never:
            return 1
        case .wifiOnly:
            return 2
        case .wifiAndCellular:
            return 3
        }
    }
}

// MARK: -

public enum MediaDownloadType: String, Equatable, CaseIterable {
    case photo
    case video
    case audio
    case document

    public var defaultPreference: MediaBandwidthPreference {
        switch self {
        case .photo:
            return .wifiAndCellular
        case .video:
            return .wifiOnly
        case .audio:
            return .wifiAndCellular
        case .document:
            return .wifiOnly
        }
    }

    public var sortKey: UInt {
        switch self {
        case .photo:
            return 1
        case .video:
            return 2
        case .audio:
            return 3
        case .document:
            return 4
        }
    }
}

// MARK: -

public extension OWSAttachmentDownloads {

    private static let keyValueStore = SDSKeyValueStore(collection: "MediaBandwidthPreferences")

    static let mediaBandwidthPreferencesDidChange = Notification.Name("PushTokensDidChange")

    static func set(mediaBandwidthPreference: MediaBandwidthPreference,
                    forMediaDownloadType mediaDownloadType: MediaDownloadType,
                    transaction: SDSAnyWriteTransaction) {
        keyValueStore.setUInt(mediaBandwidthPreference.rawValue,
                              key: mediaDownloadType.rawValue,
                              transaction: transaction)

        transaction.addAsyncCompletionOffMain {
            NotificationCenter.default.postNotificationNameAsync(mediaBandwidthPreferencesDidChange, object: nil)
        }
    }

    static func mediaBandwidthPreference(forMediaDownloadType mediaDownloadType: MediaDownloadType,
                                         transaction: SDSAnyReadTransaction) -> MediaBandwidthPreference {
        guard let rawValue = keyValueStore.getUInt(mediaDownloadType.rawValue,
                                                   transaction: transaction) else {
            return mediaDownloadType.defaultPreference
        }
        guard let value = MediaBandwidthPreference(rawValue: rawValue) else {
            owsFailDebug("Invalid value: \(rawValue)")
            return mediaDownloadType.defaultPreference
        }
        return value
    }

    static func resetMediaBandwidthPreferences(transaction: SDSAnyWriteTransaction) {
        for mediaDownloadType in MediaDownloadType.allCases {
            keyValueStore.removeValue(forKey: mediaDownloadType.rawValue, transaction: transaction)
        }
        transaction.addAsyncCompletionOffMain {
            NotificationCenter.default.postNotificationNameAsync(mediaBandwidthPreferencesDidChange, object: nil)
        }
    }

    static func loadMediaBandwidthPreferences(transaction: SDSAnyReadTransaction) -> [MediaDownloadType: MediaBandwidthPreference] {
        var result = [MediaDownloadType: MediaBandwidthPreference]()
        for mediaDownloadType in MediaDownloadType.allCases {
            result[mediaDownloadType] = mediaBandwidthPreference(forMediaDownloadType: mediaDownloadType,
                                                                 transaction: transaction)
        }
        return result
    }

    private static func autoDownloadableMediaTypes(transaction: SDSAnyReadTransaction) -> Set<MediaDownloadType> {
        let preferenceMap = loadMediaBandwidthPreferences(transaction: transaction)
        let hasWifiConnection = reachabilityManager.isReachable(via: .wifi)
        var result = Set<MediaDownloadType>()
        for (mediaDownloadType, preference) in preferenceMap {
            switch preference {
            case .never:
                continue
            case .wifiOnly:
                if hasWifiConnection {
                    result.insert(mediaDownloadType)
                }
            case .wifiAndCellular:
                result.insert(mediaDownloadType)
            }
        }
        return result
    }
}

// MARK: - Enqueue

public extension OWSAttachmentDownloads {

    func enqueueHeadlessDownloadPromise(attachmentPointer: TSAttachmentPointer) -> Promise<TSAttachmentStream> {
        return Promise { resolver in
            self.enqueueHeadlessDownload(attachmentPointer: attachmentPointer,
                                         success: resolver.fulfill,
                                         failure: resolver.reject)
        }.map { attachments in
            assert(attachments.count == 1)
            guard let attachment = attachments.first else {
                throw OWSAssertionError("Missing attachment.")
            }
            return attachment
        }
    }

    @objc(enqueueHeadlessDownloadWithAttachmentPointer:success:failure:)
    func enqueueHeadlessDownload(attachmentPointer: TSAttachmentPointer,
                                 success: @escaping ([TSAttachmentStream]) -> Void,
                                 failure: @escaping (Error) -> Void) {

        // Headless downloads are always .other
        let category: AttachmentCategory = .other
        // Headless downloads always bypass.
        let downloadBehavior: AttachmentDownloadBehavior = .bypassAll
        let jobType: JobType = .headlessAttachment(attachmentPointer: attachmentPointer)
        let jobRequest = JobRequest(jobType: jobType, category: category)
        enqueueDownload(jobRequest: jobRequest,
                        downloadBehavior: downloadBehavior,
                        success: success,
                        failure: failure)
    }

    @objc(enqueueMessageDownloadWithAttachmentPointer:message:category:downloadBehavior:success:failure:)
    func enqueueMessageDownload(attachmentPointer: TSAttachmentPointer,
                                message: TSMessage,
                                category: AttachmentCategory,
                                downloadBehavior: AttachmentDownloadBehavior,
                                success: @escaping ([TSAttachmentStream]) -> Void,
                                failure: @escaping (Error) -> Void) {
        let jobType: JobType = .messageAttachment(attachmentId: attachmentPointer.uniqueId,
                                                  message: message)
        let jobRequest = JobRequest(jobType: jobType, category: category)
        enqueueDownload(jobRequest: jobRequest,
                        downloadBehavior: downloadBehavior,
                        success: success,
                        failure: failure)
    }

    private func enqueueDownload(jobRequest: JobRequest,
                                 downloadBehavior: AttachmentDownloadBehavior,
                                 success: @escaping ([TSAttachmentStream]) -> Void,
                                 failure: @escaping (Error) -> Void) {

        guard !CurrentAppContext().isRunningTests else {
            Self.serialQueue.async {
                failure(OWSAttachmentDownloads.buildError())
            }
            return
        }

        Self.serialQueue.async {
            Self.databaseStorage.read { transaction in
                self.enqueueJobs(jobRequests: [jobRequest],
                                 downloadBehavior: downloadBehavior,
                                 transaction: transaction,
                                 success: success,
                                 failure: failure)
            }
        }
    }

    @objc
    func enqueueDownloadOfAllAttachments(forThread thread: TSThread,
                                         transaction: SDSAnyReadTransaction) {

        var promises = [Promise<Void>]()
        let unfairLock = UnfairLock()
        var attachmentStreams = [TSAttachmentStream]()

        do {
            let finder = GRDBInteractionFinder(threadUniqueId: thread.uniqueId)
            try finder.enumerateMessagesWithAttachments(transaction: transaction.unwrapGrdbRead) { (message, _) in
                let (promise, resolver) = Promise<Void>.pending()
                promises.append(promise)
                self.enqueueDownloadOfAttachments(forMessageId: message.uniqueId,
                                                  attachmentGroup: .allAttachmentsIncoming,
                                                  downloadBehavior: .default,
                                                  touchMessageImmediately: false,
                                                  success: { downloadedAttachments in
                                                    unfairLock.withLock {
                                                        attachmentStreams.append(contentsOf: downloadedAttachments)
                                                    }
                                                    resolver.fulfill(())
                                                  },
                                                  failure: { error in
                                                    resolver.reject(error)
                                                  })
            }

            guard !promises.isEmpty else {
                return
            }

            // Block until _all_ promises have either succeeded or failed.
            _ = firstly(on: Self.serialQueue) {
                when(fulfilled: promises)
            }.done(on: Self.serialQueue) { _ in
                let attachmentStreamsCopy = unfairLock.withLock { attachmentStreams }
                Logger.info("Successfully downloaded attachments for whitelisted thread: \(attachmentStreamsCopy.count).")
            }.catch(on: Self.serialQueue) { error in
                Logger.warn("Failed to download attachments for whitelisted thread.")
                owsFailDebugUnlessNetworkFailure(error)
            }
        } catch {
            owsFailDebug("Error: \(error)")
        }
    }

    // TODO: Can we simplify this?
    @objc
    enum AttachmentGroup: UInt, Equatable {
        case allAttachmentsIncoming
        case bodyAttachmentsIncoming
        case allAttachmentsOfAnyKind
        case bodyAttachmentsOfAnyKind

        var justIncomingAttachments: Bool {
            switch self {
            case .bodyAttachmentsOfAnyKind, .allAttachmentsOfAnyKind:
                return false
            case .bodyAttachmentsIncoming, .allAttachmentsIncoming:
                return true
            }
        }

        var justBodyAttachments: Bool {
            switch self {
            case .allAttachmentsIncoming, .allAttachmentsOfAnyKind:
                return false
            case .bodyAttachmentsIncoming, .bodyAttachmentsOfAnyKind:
                return true
            }
        }
    }

    @objc
    enum AttachmentCategory: UInt, Equatable, CustomStringConvertible {
        case bodyMediaImage
        case bodyMediaVideo
        case bodyAudioVoiceMemo
        case bodyAudioOther
        case bodyFile
        case bodyOversizeText
        case stickerSmall
        case stickerLarge
        case quotedReplyThumbnail
        case linkedPreviewThumbnail
        case contactShareAvatar
        case other

        var isSticker: Bool {
            (self == .stickerSmall || self == .stickerLarge)
        }

        // MARK: - CustomStringConvertible

        public var description: String {
            switch self {
            case .bodyMediaImage:
                return ".bodyMediaImage"
            case .bodyMediaVideo:
                return ".bodyMediaVideo"
            case .bodyAudioVoiceMemo:
                return ".bodyAudioVoiceMemo"
            case .bodyAudioOther:
                return ".bodyAudioOther"
            case .bodyFile:
                return ".bodyFile"
            case .bodyOversizeText:
                return ".bodyOversizeText"
            case .stickerSmall:
                return ".stickerSmall"
            case .stickerLarge:
                return ".stickerLarge"
            case .quotedReplyThumbnail:
                return ".quotedReplyThumbnail"
            case .linkedPreviewThumbnail:
                return ".linkedPreviewThumbnail"
            case .contactShareAvatar:
                return ".contactShareAvatar"
            case .other:
                return ".other"
            default:
                owsFailDebug("unexpected value: \(self.rawValue)")
                return "Unknown"
            }
        }
    }

    private class func buildJobRequests(forMessage message: TSMessage,
                                        attachmentGroup: AttachmentGroup,
                                        transaction: SDSAnyReadTransaction) -> [JobRequest] {

        var jobRequests = [JobRequest]()
        var attachmentIds = Set<AttachmentId>()

        func addJobRequest(attachment: TSAttachment, category: AttachmentCategory) {

            if let attachmentPointer = attachment as? TSAttachmentPointer {
                if attachmentPointer.pointerType == .restoring {
                    Logger.warn("Ignoring restoring attachment.")
                    return
                }
                if attachmentGroup.justIncomingAttachments,
                   attachmentPointer.pointerType != .incoming {
                    Logger.warn("Ignoring non-incoming attachment.")
                    return
                }
            }

            let attachmentId = attachment.uniqueId
            guard !attachmentIds.contains(attachmentId) else {
                // Ignoring duplicate
                return
            }
            attachmentIds.insert(attachmentId)
            let jobType = JobType.messageAttachment(attachmentId: attachmentId, message: message)
            jobRequests.append(JobRequest(jobType: jobType, category: category))
        }

        func addJobRequest(attachmentId: AttachmentId, category: AttachmentCategory) {
            guard let attachment = TSAttachment.anyFetch(uniqueId: attachmentId,
                                                         transaction: transaction) else {
                owsFailDebug("Missing attachment: \(attachmentId)")
                return
            }
            addJobRequest(attachment: attachment, category: category)
        }

        for attachmentId in message.attachmentIds {
            guard let attachment = TSAttachment.anyFetch(uniqueId: attachmentId,
                                                         transaction: transaction) else {
                owsFailDebug("Missing attachment: \(attachmentId)")
                continue
            }
            let category: AttachmentCategory = {
                if attachment.isImage {
                    return .bodyMediaImage
                } else if attachment.isVideo {
                    return .bodyMediaVideo
                } else if attachment.isVoiceMessage {
                    return .bodyAudioVoiceMemo
                } else if attachment.isAudio {
                    return .bodyAudioOther
                } else if attachment.isOversizeText {
                    return .bodyOversizeText
                } else {
                    return .bodyFile
                }
            }()
            addJobRequest(attachment: attachment, category: category)
        }

        guard !attachmentGroup.justBodyAttachments else {
            return jobRequests
        }

        if let quotedMessage = message.quotedMessage {
            for attachmentId in quotedMessage.thumbnailAttachmentStreamIds() {
                addJobRequest(attachmentId: attachmentId, category: .quotedReplyThumbnail)
            }
            if let attachmentId = quotedMessage.thumbnailAttachmentPointerId() {
                addJobRequest(attachmentId: attachmentId, category: .quotedReplyThumbnail)
            }
        }

        if let attachmentId = message.contactShare?.avatarAttachmentId {
            addJobRequest(attachmentId: attachmentId, category: .contactShareAvatar)
        }

        if let attachmentId = message.linkPreview?.imageAttachmentId {
            addJobRequest(attachmentId: attachmentId, category: .linkedPreviewThumbnail)
        }

        if let attachmentId = message.messageSticker?.attachmentId {
            if let attachment = TSAttachment.anyFetch(uniqueId: attachmentId,
                                                      transaction: transaction) {
                owsAssertDebug(attachment.byteCount > 0)
                let autoDownloadSizeThreshold: UInt32 = 100 * 1024
                if attachment.byteCount > autoDownloadSizeThreshold {
                    addJobRequest(attachmentId: attachmentId, category: .stickerLarge)
                } else {
                    addJobRequest(attachmentId: attachmentId, category: .stickerSmall)
                }
            } else {
                owsFailDebug("Missing attachment: \(attachmentId)")
            }
        }

        return jobRequests
    }

    @objc
    func enqueueDownloadOfAttachments(forMessageId messageId: String,
                                      attachmentGroup: AttachmentGroup,
                                      downloadBehavior: AttachmentDownloadBehavior,
                                      touchMessageImmediately: Bool,
                                      success: @escaping ([TSAttachmentStream]) -> Void,
                                      failure: @escaping (Error) -> Void) {

        Self.serialQueue.async {
            guard !CurrentAppContext().isRunningTests else {
                failure(Self.buildError())
                return
            }
            Self.databaseStorage.read { transaction in
                guard let message = TSMessage.anyFetchMessage(uniqueId: messageId, transaction: transaction) else {
                    failure(Self.buildError())
                    return
                }
                let jobRequests = Self.buildJobRequests(forMessage: message,
                                                        attachmentGroup: attachmentGroup,
                                                        transaction: transaction)
                guard !jobRequests.isEmpty else {
                    success([])
                    return
                }
                self.enqueueJobs(jobRequests: jobRequests,
                                 downloadBehavior: downloadBehavior,
                                 transaction: transaction,
                                 success: { attachmentStreams in
                                    success(attachmentStreams)

                                    Self.updateQuotedMessageThumbnail(messageId: messageId,
                                                                      jobRequests: jobRequests,
                                                                      attachmentStreams: attachmentStreams)
                                 },
                                 failure: failure)

                if touchMessageImmediately {
                    Self.databaseStorage.asyncWrite { transaction in
                        Self.databaseStorage.touch(interaction: message,
                                                   shouldReindex: false,
                                                   transaction: transaction)
                    }
                }
            }
        }
    }

    private class func updateQuotedMessageThumbnail(messageId: String,
                                                    jobRequests: [JobRequest],
                                                    attachmentStreams: [TSAttachmentStream]) {
        guard !attachmentStreams.isEmpty else {
            // Don't bothe
            return
        }
        let quotedMessageThumbnailDownloads = jobRequests.filter { $0.category == .quotedReplyThumbnail }
        guard !quotedMessageThumbnailDownloads.isEmpty else {
            return
        }
        Self.databaseStorage.write { transaction in
            guard let message = TSMessage.anyFetchMessage(uniqueId: messageId, transaction: transaction) else {
                Logger.warn("Missing message.")
                return
            }
            guard let thumbnailAttachmentPointerId = message.quotedMessage?.thumbnailAttachmentPointerId(),
                  !thumbnailAttachmentPointerId.isEmpty else {
                return
            }
            guard let quotedMessageThumbnail = (attachmentStreams.filter { $0.uniqueId == thumbnailAttachmentPointerId }.first) else {
                return
            }
            message.setQuotedMessageThumbnailAttachmentStream(quotedMessageThumbnail)
        }
    }

    private func enqueueJobs(jobRequests: [JobRequest],
                             downloadBehavior: AttachmentDownloadBehavior,
                             transaction: SDSAnyReadTransaction,
                             success: @escaping ([TSAttachmentStream]) -> Void,
                             failure: @escaping (Error) -> Void) {

        let unfairLock = UnfairLock()
        var attachmentStreams = [TSAttachmentStream]()
        var promises = [Promise<Void>]()
        for jobRequest in jobRequests {
            if let attachmentStream = jobRequest.loadLatestAttachment(transaction: transaction) as? TSAttachmentStream {
                unfairLock.withLock {
                    attachmentStreams.append(attachmentStream)
                }
                continue
            }
            let job = Job(jobRequest: jobRequest, downloadBehavior: downloadBehavior)
            self.enqueueJob(job: job)
            let promise = firstly {
                job.promise
            }.map(on: Self.serialQueue) { attachmentStream in
                unfairLock.withLock {
                    attachmentStreams.append(attachmentStream)
                }
            }
            promises.append(promise)
        }

        guard !promises.isEmpty else {
            Self.serialQueue.async {
                success(attachmentStreams)
            }
            return
        }

        // Block until _all_ promises have either succeeded or failed.
        _ = firstly(on: Self.serialQueue) {
            when(fulfilled: promises)
        }.done(on: Self.serialQueue) { _ in
            let attachmentStreamsCopy = unfairLock.withLock { attachmentStreams }
            Logger.info("Attachment downloads succeeded: \(attachmentStreamsCopy.count).")

            success(attachmentStreamsCopy)
        }.catch(on: Self.serialQueue) { error in
            Logger.warn("Attachment downloads failed.")
            if case AttachmentDownloadError.cancelled = error {
                // Do nothing.
            } else {
                owsFailDebugUnlessNetworkFailure(error)
            }

            failure(error)
        }
    }

    @objc
    static func buildError() -> Error {
        OWSErrorWithCodeDescription(.attachmentDownloadFailed,
                                    NSLocalizedString("ERROR_MESSAGE_ATTACHMENT_DOWNLOAD_FAILED",
                                                      comment: "Error message indicating that attachment download(s) failed."))
    }

    // MARK: -

    @objc
    static let serialQueue: DispatchQueue = {
        return DispatchQueue(label: "org.whispersystems.signal.download",
                             qos: .utility,
                             autoreleaseFrequency: .workItem)
    }()

    // We want to avoid large downloads from a compromised or buggy service.
    private static let maxDownloadSize = 150 * 1024 * 1024

    private func retrieveAttachment(job: Job,
                                    attachmentPointer: TSAttachmentPointer) -> Promise<TSAttachmentStream> {

        var backgroundTask: OWSBackgroundTask? = OWSBackgroundTask(label: "retrieveAttachment")

        return firstly(on: Self.serialQueue) { () -> Promise<URL> in
            self.download(job: job, attachmentPointer: attachmentPointer)
        }.then(on: Self.serialQueue) { (encryptedFileUrl: URL) -> Promise<TSAttachmentStream> in
            Self.decrypt(encryptedFileUrl: encryptedFileUrl,
                         attachmentPointer: attachmentPointer)
        }.ensure(on: Self.serialQueue) {
            guard backgroundTask != nil else {
                owsFailDebug("Missing backgroundTask.")
                return
            }
            backgroundTask = nil
        }
    }

    private class DownloadState {
        let job: Job
        let attachmentPointer: TSAttachmentPointer
        let startDate = Date()

        required init(job: Job, attachmentPointer: TSAttachmentPointer) {
            self.job = job
            self.attachmentPointer = attachmentPointer
        }
    }

    private func download(job: Job, attachmentPointer: TSAttachmentPointer) -> Promise<URL> {

        let downloadState = DownloadState(job: job, attachmentPointer: attachmentPointer)

        return firstly(on: Self.serialQueue) { () -> Promise<URL> in
            self.downloadAttempt(downloadState: downloadState)
        }
    }

    private func downloadAttempt(downloadState: DownloadState,
                                 resumeData: Data? = nil,
                                 attemptIndex: UInt = 0) -> Promise<URL> {

        let (promise, resolver) = Promise<URL>.pending()

        firstly(on: Self.serialQueue) { () -> Promise<OWSUrlDownloadResponse> in
            let attachmentPointer = downloadState.attachmentPointer
            let urlSession = Self.signalService.urlSessionForCdn(cdnNumber: attachmentPointer.cdnNumber)
            let urlPath = try Self.urlPath(for: downloadState)
            let headers: [String: String] = [
                "Content-Type": OWSMimeTypeApplicationOctetStream
            ]

            let progress = { (task: URLSessionTask, progress: Progress) in
                self.handleDownloadProgress(downloadState: downloadState,
                                            task: task,
                                            progress: progress,
                                            resolver: resolver)
            }

            if let resumeData = resumeData {
                return urlSession.urlDownloadTaskPromise(resumeData: resumeData,
                                                         progress: progress)
            } else {
                return urlSession.urlDownloadTaskPromise(urlPath,
                                                         method: .get,
                                                         headers: headers,
                                                         progress: progress)
            }
        }.map(on: Self.serialQueue) { (response: OWSUrlDownloadResponse) in
            let downloadUrl = response.downloadUrl
            guard let fileSize = OWSFileSystem.fileSize(of: downloadUrl) else {
                throw OWSAssertionError("Could not determine attachment file size.")
            }
            guard fileSize.int64Value <= Self.maxDownloadSize else {
                throw OWSAssertionError("Attachment download length exceeds max size.")
            }
            return downloadUrl
        }.recover(on: Self.serialQueue) { (error: Error) -> Promise<URL> in
            Logger.warn("Error: \(error)")

            let maxAttemptCount = 16
            if IsNetworkConnectivityFailure(error),
               attemptIndex < maxAttemptCount {

                return firstly {
                    // Wait briefly before retrying.
                    after(seconds: 0.25)
                }.then { () -> Promise<URL> in
                    if let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
                       !resumeData.isEmpty {
                        return self.downloadAttempt(downloadState: downloadState, resumeData: resumeData, attemptIndex: attemptIndex + 1)
                    } else {
                        return self.downloadAttempt(downloadState: downloadState, attemptIndex: attemptIndex + 1)
                    }
                }
            } else {
                throw error
            }
        }.done(on: Self.serialQueue) { url in
            resolver.fulfill(url)
        }.catch(on: Self.serialQueue) { error in
            resolver.reject(error)
        }

        return promise
    }

    private class func urlPath(for downloadState: DownloadState) throws -> String {

        let attachmentPointer = downloadState.attachmentPointer
        let urlPath: String
        if attachmentPointer.cdnKey.count > 0 {
            guard let encodedKey = attachmentPointer.cdnKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                throw OWSAssertionError("Invalid cdnKey.")
            }
            urlPath = "attachments/\(encodedKey)"
        } else {
            urlPath = String(format: "attachments/%llu", attachmentPointer.serverId)
        }
        return urlPath
    }

    private enum AttachmentDownloadError: Error {
        case cancelled
        case oversize
    }

    private func handleDownloadProgress(downloadState: DownloadState,
                                        task: URLSessionTask,
                                        progress: Progress,
                                        resolver: Resolver<URL>) {

        guard !self.shouldCancelJob(downloadState: downloadState) else {
            Logger.info("Cancelling job.")
            task.cancel()
            resolver.reject(AttachmentDownloadError.cancelled)
            return
        }

        // Don't do anything until we've received at least one byte of data.
        guard progress.completedUnitCount > 0 else {
            return
        }

        guard progress.totalUnitCount <= Self.maxDownloadSize,
              progress.completedUnitCount <= Self.maxDownloadSize else {
            // A malicious service might send a misleading content length header,
            // so....
            //
            // If the current downloaded bytes or the expected total byes
            // exceed the max download size, abort the download.
            owsFailDebug("Attachment download exceed expected content length: \(progress.totalUnitCount), \(progress.completedUnitCount).")
            task.cancel()
            resolver.reject(AttachmentDownloadError.oversize)
            return
        }

        downloadState.job.progress = CGFloat(progress.fractionCompleted)

        // Use a slightly non-zero value to ensure that the progress
        // indicator shows up as quickly as possible.
        let progressTheta: Double = 0.001
        Self.fireProgressNotification(progress: max(progressTheta, progress.fractionCompleted),
                                      attachmentId: downloadState.attachmentPointer.uniqueId)
    }

    // MARK: -

    private class func decrypt(encryptedFileUrl: URL,
                               attachmentPointer: TSAttachmentPointer) -> Promise<TSAttachmentStream> {

        // Use serialQueue to ensure that we only load into memory
        // & decrypt a single attachment at a time.
        return firstly(on: Self.serialQueue) { () -> TSAttachmentStream in
            let cipherText = try Data(contentsOf: encryptedFileUrl)
            return try Self.decrypt(cipherText: cipherText,
                                    attachmentPointer: attachmentPointer)
        }.ensure(on: Self.serialQueue) {
            do {
                try OWSFileSystem.deleteFileIfExists(url: encryptedFileUrl)
            } catch {
                owsFailDebug("Error: \(error).")
            }
        }
    }

    private class func decrypt(cipherText: Data,
                               attachmentPointer: TSAttachmentPointer) throws -> TSAttachmentStream {

        guard let encryptionKey = attachmentPointer.encryptionKey else {
            throw OWSAssertionError("Missing encryptionKey.")
        }
        return try autoreleasepool {
            let plaintext: Data = try Cryptography.decryptAttachment(cipherText,
                                                                     withKey: encryptionKey,
                                                                     digest: attachmentPointer.digest,
                                                                     unpaddedSize: attachmentPointer.byteCount)

            let attachmentStream = databaseStorage.read { transaction in
                TSAttachmentStream(pointer: attachmentPointer, transaction: transaction)
            }
            try attachmentStream.write(plaintext)

            return attachmentStream
        }
    }

    // MARK: -

    @objc
    static let attachmentDownloadProgressNotification = Notification.Name("AttachmentDownloadProgressNotification")
    @objc
    static let attachmentDownloadProgressKey = "attachmentDownloadProgressKey"
    @objc
    static let attachmentDownloadAttachmentIDKey = "attachmentDownloadAttachmentIDKey"

    private class func fireProgressNotification(progress: Double, attachmentId: AttachmentId) {
        NotificationCenter.default.postNotificationNameAsync(attachmentDownloadProgressNotification,
                                                             object: nil,
                                                             userInfo: [
                                                                attachmentDownloadProgressKey: NSNumber(value: progress),
                                                                attachmentDownloadAttachmentIDKey: attachmentId
                                                             ])
    }
}
