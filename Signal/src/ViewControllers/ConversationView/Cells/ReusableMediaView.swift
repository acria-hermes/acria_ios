//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit

// MARK: -

// The loadState property allows us to:
//
// * Make sure we only have one load attempt
//   enqueued at a time for a given piece of media.
// * We never retry media that can't be loaded.
// * We skip media loads which are no longer
//   necessary by the time they reach the front
//   of the queue.

private enum LoadState {
    case unloaded
    case loading
    case loaded
    case failed
}

// MARK: -

@objc
public protocol MediaViewAdapter {
    var mediaView: UIView { get }
    var isLoaded: Bool { get }
    var cacheKey: String { get }
    var shouldBeRenderedByYY: Bool { get }

    func applyMedia(_ media: AnyObject)
    func unloadMedia()
}

// MARK: -

public protocol MediaViewAdapterSwift: MediaViewAdapter {
    func loadMedia() -> Promise<AnyObject>
}

// MARK: -

public enum ReusableMediaError: Error {
    case invalidMedia
    case redundantLoad
}

// MARK: -

@objc
public class ReusableMediaView: NSObject {

    private let mediaViewAdapter: MediaViewAdapterSwift
    private let mediaCache: CVMediaCache

    @objc
    public var mediaView: UIView {
        mediaViewAdapter.mediaView
    }

    var isVideo: Bool {
        mediaViewAdapter as? MediaViewAdapterVideo != nil
    }

    // MARK: - LoadState

    // Thread-safe access to load state.
    //
    // We use a "box" class so that we can capture a reference
    // to this box (rather than self) and a) safely access
    // if off the main thread b) not prevent deallocation of
    // self.
    private let _loadState = AtomicValue(LoadState.unloaded)
    private var loadState: LoadState {
        get {
            return _loadState.get()
        }
        set {
            _loadState.set(newValue)
        }
    }

    // MARK: - Ownership

    @objc
    public weak var owner: NSObject?

    // MARK: - Initializers

    @objc
    public required init(mediaViewAdapter: MediaViewAdapter,
                         mediaCache: CVMediaCache) {
        self.mediaViewAdapter = mediaViewAdapter as! MediaViewAdapterSwift
        self.mediaCache = mediaCache
    }

    deinit {
        AssertIsOnMainThread()

        loadState = .unloaded
    }

    // MARK: - Initializers

    @objc
    public func load() {
        AssertIsOnMainThread()

        switch loadState {
        case .unloaded:
            loadState = .loading

            tryToLoadMedia()
        case .loading, .loaded, .failed:
            break
        }
    }

    @objc
    public func unload() {
        AssertIsOnMainThread()

        loadState = .unloaded

        mediaViewAdapter.unloadMedia()
    }

    // TODO: It would be preferable to figure out some way to use ReverseDispatchQueue.
    private static let serialQueue = DispatchQueue(label: "org.signal.reusableMediaView")

    private func tryToLoadMedia() {
        AssertIsOnMainThread()

        guard !mediaViewAdapter.isLoaded else {
            // Already loaded.
            return
        }
        guard let loadOwner = self.owner else {
            owsFailDebug("Missing owner for load.")
            return
        }

        // It's critical that we update loadState once
        // our load attempt is complete.
        let loadCompletion: (AnyObject?) -> Void = { [weak self] (possibleMedia) in
            AssertIsOnMainThread()

            guard let self = self else {
                return
            }
            guard loadOwner == self.owner else {
                // Owner has changed; ignore.
                return
            }
            guard self.loadState == .loading else {
                Logger.verbose("Skipping obsolete load.")
                return
            }
            guard let media = possibleMedia else {
                self.loadState = .failed
                return
            }

            self.mediaViewAdapter.applyMedia(media)

            self.loadState = .loaded
        }

        guard loadState == .loading else {
            owsFailDebug("Unexpected load state: \(loadState)")
            return
        }

        let mediaViewAdapter = self.mediaViewAdapter
        let cacheKey = mediaViewAdapter.cacheKey
        let mediaCache = self.mediaCache
        if let media = mediaCache.getMedia(cacheKey, isAnimated: mediaViewAdapter.shouldBeRenderedByYY) {
            Logger.verbose("media cache hit")
            loadCompletion(media)
            return
        }

        Logger.verbose("media cache miss")

        let loadState = self._loadState

        firstly(on: Self.serialQueue) { () -> Promise<AnyObject> in
            guard loadState.get() == .loading else {
                throw ReusableMediaError.redundantLoad
            }
            return mediaViewAdapter.loadMedia()
        }.done(on: .main) { (media: AnyObject) in
            mediaCache.setMedia(media, forKey: cacheKey, isAnimated: mediaViewAdapter.shouldBeRenderedByYY)

            loadCompletion(media)
        }.catch(on: .main) { (error: Error) in
            switch error {
            case ReusableMediaError.redundantLoad,
                 ReusableMediaError.invalidMedia:
                Logger.warn("Error: \(error)")
            default:
                owsFailDebug("Error: \(error)")
            }
            loadCompletion(nil)
        }
    }
}

// MARK: -

class MediaViewAdapterBlurHash: MediaViewAdapterSwift {

    public let shouldBeRenderedByYY = false
    let blurHash: String
    let imageView = UIImageView()

    init(blurHash: String) {
        self.blurHash = blurHash
    }

    var mediaView: UIView {
        imageView
    }

    var isLoaded: Bool {
        imageView.image != nil
    }

    var cacheKey: String {
        // NOTE: in the blurhash case, we use the blurHash itself as the
        // cachekey to avoid conflicts with the actual attachment contents.
        blurHash
    }

    func loadMedia() -> Promise<AnyObject> {
        guard let image = BlurHash.image(for: blurHash) else {
            return Promise(error: OWSAssertionError("Missing image for blurHash."))
        }
        return Promise.value(image)
    }

    func applyMedia(_ media: AnyObject) {
        AssertIsOnMainThread()

        guard let image = media as? UIImage else {
            owsFailDebug("Media has unexpected type: \(type(of: media))")
            return
        }
        imageView.image = image
    }

    func unloadMedia() {
        AssertIsOnMainThread()

        imageView.image = nil
    }
}

// MARK: -

class MediaViewAdapterAnimated: MediaViewAdapterSwift {

    public let shouldBeRenderedByYY = true
    let attachmentStream: TSAttachmentStream
    let imageView = YYAnimatedImageView()

    init(attachmentStream: TSAttachmentStream) {
        self.attachmentStream = attachmentStream
    }

    var mediaView: UIView {
        imageView
    }

    var isLoaded: Bool {
        imageView.image != nil
    }

    var cacheKey: String {
        attachmentStream.uniqueId
    }

    func loadMedia() -> Promise<AnyObject> {
        guard attachmentStream.isValidImage else {
            return Promise(error: ReusableMediaError.invalidMedia)
        }
        guard let filePath = attachmentStream.originalFilePath else {
            return Promise(error: OWSAssertionError("Attachment stream missing original file path."))
        }
        guard let animatedImage = YYImage(contentsOfFile: filePath) else {
            return Promise(error: OWSAssertionError("Invalid animated image."))
        }
        return Promise.value(animatedImage)
    }

    func applyMedia(_ media: AnyObject) {
        AssertIsOnMainThread()

        guard let image = media as? YYImage else {
            owsFailDebug("Media has unexpected type: \(type(of: media))")
            return
        }
        imageView.image = image
    }

    func unloadMedia() {
        AssertIsOnMainThread()

        imageView.image = nil
    }
}

// MARK: -

class MediaViewAdapterStill: MediaViewAdapterSwift {

    public let shouldBeRenderedByYY = false
    let attachmentStream: TSAttachmentStream
    let imageView = UIImageView()

    init(attachmentStream: TSAttachmentStream) {
        self.attachmentStream = attachmentStream
    }

    var mediaView: UIView {
        imageView
    }

    var isLoaded: Bool {
        imageView.image != nil
    }

    var cacheKey: String {
        attachmentStream.uniqueId
    }

    func loadMedia() -> Promise<AnyObject> {
        guard attachmentStream.isValidImage else {
            return Promise(error: ReusableMediaError.invalidMedia)
        }
        let (promise, resolver) = Promise<AnyObject>.pending()
        let possibleThumbnail = attachmentStream.thumbnailImageLarge(success: { (image) in
            resolver.fulfill(image)
        }, failure: {
            resolver.reject(OWSAssertionError("Could not load thumbnail"))
        })
        // TSAttachmentStream's thumbnail methods return a UIImage sync
        // if the thumbnail already exists. Otherwise, the callbacks are invoked async.
        if let thumbnail = possibleThumbnail {
            resolver.fulfill(thumbnail)
        }
        return promise
    }

    func applyMedia(_ media: AnyObject) {
        AssertIsOnMainThread()

        guard let image = media as? UIImage else {
            owsFailDebug("Media has unexpected type: \(type(of: media))")
            return
        }
        imageView.image = image
    }

    func unloadMedia() {
        AssertIsOnMainThread()

        imageView.image = nil
    }
}

// MARK: -

class MediaViewAdapterVideo: MediaViewAdapterSwift {

    public let shouldBeRenderedByYY = false
    let attachmentStream: TSAttachmentStream
    let imageView = UIImageView()

    init(attachmentStream: TSAttachmentStream) {
        self.attachmentStream = attachmentStream
    }

    var mediaView: UIView {
        imageView
    }

    var isLoaded: Bool {
        imageView.image != nil
    }

    var cacheKey: String {
        attachmentStream.uniqueId
    }

    func loadMedia() -> Promise<AnyObject> {
        guard attachmentStream.isValidVideo else {
            return Promise(error: ReusableMediaError.invalidMedia)
        }
        let (promise, resolver) = Promise<AnyObject>.pending()
        let possibleThumbnail = attachmentStream.thumbnailImageLarge(success: { (image) in
            resolver.fulfill(image)
        }, failure: {
            resolver.reject(OWSAssertionError("Could not load thumbnail"))
        })
        // TSAttachmentStream's thumbnail methods return a UIImage sync
        // if the thumbnail already exists. Otherwise, the callbacks are invoked async.
        if let thumbnail = possibleThumbnail {
            resolver.fulfill(thumbnail)
        }
        return promise
    }

    func applyMedia(_ media: AnyObject) {
        AssertIsOnMainThread()

        guard let image = media as? UIImage else {
            owsFailDebug("Media has unexpected type: \(type(of: media))")
            return
        }
        imageView.image = image
    }

    func unloadMedia() {
        AssertIsOnMainThread()

        imageView.image = nil
    }
}

// MARK: -

@objc
public class MediaViewAdapterSticker: NSObject, MediaViewAdapterSwift {

    public let shouldBeRenderedByYY: Bool
    let attachmentStream: TSAttachmentStream
    let imageView: UIImageView

    @objc
    public init(attachmentStream: TSAttachmentStream) {
        self.shouldBeRenderedByYY = attachmentStream.shouldBeRenderedByYY
        self.attachmentStream = attachmentStream

        if shouldBeRenderedByYY {
            imageView = YYAnimatedImageView()
        } else {
            imageView = UIImageView()
        }

        imageView.contentMode = .scaleAspectFit
    }

    public var mediaView: UIView {
        imageView
    }

    public var isLoaded: Bool {
        imageView.image != nil
    }

    public var cacheKey: String {
        attachmentStream.uniqueId
    }

    public func loadMedia() -> Promise<AnyObject> {
        guard attachmentStream.isValidImage else {
            return Promise(error: ReusableMediaError.invalidMedia)
        }
        guard let filePath = attachmentStream.originalFilePath else {
            return Promise(error: OWSAssertionError("Attachment stream missing original file path."))
        }
        let imageMetadata = NSData.imageMetadata(withPath: filePath, mimeType: nil)
        Logger.verbose("imageMetadata: \(NSStringForImageFormat(imageMetadata.imageFormat))")
        Logger.flush()
        if shouldBeRenderedByYY {
            guard let animatedImage = YYImage(contentsOfFile: filePath) else {
                return Promise(error: OWSAssertionError("Invalid animated image."))
            }
            return Promise.value(animatedImage)
        } else {
            guard let image = UIImage(contentsOfFile: filePath) else {
                return Promise(error: OWSAssertionError("Invalid image."))
            }
            return Promise.value(image)
        }
    }

    public func applyMedia(_ media: AnyObject) {
        AssertIsOnMainThread()

        if shouldBeRenderedByYY {
            guard let image = media as? YYImage else {
                owsFailDebug("Media has unexpected type: \(type(of: media))")
                return
            }
            imageView.image = image
        } else {
            guard let image = media as? UIImage else {
                owsFailDebug("Media has unexpected type: \(type(of: media))")
                return
            }
            imageView.image = image
        }
    }

    public func unloadMedia() {
        AssertIsOnMainThread()

        imageView.image = nil
    }
}
