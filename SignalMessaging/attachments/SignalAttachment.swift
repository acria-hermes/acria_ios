//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation
import MobileCoreServices
import SignalServiceKit
import PromiseKit
import AVFoundation
import YYImage

enum SignalAttachmentError: Error {
    case missingData
    case fileSizeTooLarge
    case invalidData
    case couldNotParseImage
    case couldNotConvertImage
    case couldNotConvertToMpeg4
    case couldNotRemoveMetadata
    case invalidFileFormat
    case couldNotResizeImage
}

extension String {
    var filenameWithoutExtension: String {
        return (self as NSString).deletingPathExtension
    }

    var fileExtension: String? {
        return (self as NSString).pathExtension
    }

    func appendingFileExtension(_ fileExtension: String) -> String {
        guard let result = (self as NSString).appendingPathExtension(fileExtension) else {
            owsFailDebug("Failed to append file extension: \(fileExtension) to string: \(self)")
            return self
        }
        return result
    }
}

extension CGImage {
    fileprivate var hasAlpha: Bool {
        switch self.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            return true
        @unknown default:
            // better safe than sorry
            return true
        }
    }
}

extension SignalAttachmentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingData:
            return NSLocalizedString("ATTACHMENT_ERROR_MISSING_DATA", comment: "Attachment error message for attachments without any data")
        case .fileSizeTooLarge:
            return NSLocalizedString("ATTACHMENT_ERROR_FILE_SIZE_TOO_LARGE", comment: "Attachment error message for attachments whose data exceed file size limits")
        case .invalidData:
            return NSLocalizedString("ATTACHMENT_ERROR_INVALID_DATA", comment: "Attachment error message for attachments with invalid data")
        case .couldNotParseImage:
            return NSLocalizedString("ATTACHMENT_ERROR_COULD_NOT_PARSE_IMAGE", comment: "Attachment error message for image attachments which cannot be parsed")
        case .couldNotConvertImage:
            return NSLocalizedString("ATTACHMENT_ERROR_COULD_NOT_CONVERT_TO_JPEG", comment: "Attachment error message for image attachments which could not be converted to JPEG")
        case .invalidFileFormat:
            return NSLocalizedString("ATTACHMENT_ERROR_INVALID_FILE_FORMAT", comment: "Attachment error message for attachments with an invalid file format")
        case .couldNotConvertToMpeg4:
            return NSLocalizedString("ATTACHMENT_ERROR_COULD_NOT_CONVERT_TO_MP4", comment: "Attachment error message for video attachments which could not be converted to MP4")
        case .couldNotRemoveMetadata:
            return NSLocalizedString("ATTACHMENT_ERROR_COULD_NOT_REMOVE_METADATA", comment: "Attachment error message for image attachments in which metadata could not be removed")
        case .couldNotResizeImage:
            return NSLocalizedString("ATTACHMENT_ERROR_COULD_NOT_RESIZE_IMAGE", comment: "Attachment error message for image attachments which could not be resized")
        }
    }
}

@objc
public enum TSImageQualityTier: UInt {
    case original
    case high
    case mediumHigh
    case medium
    case mediumLow
    case low
}

@objc
public enum TSImageQuality: UInt {
    case original
    case medium
    case compact

    func imageQualityTier() -> TSImageQualityTier {
        switch self {
        case .original:
            return .original
        case .medium:
            return .mediumHigh
        case .compact:
            return .medium
        }
    }
}

// Represents a possible attachment to upload.
// The attachment may be invalid.
//
// Signal attachments are subject to validation and 
// in some cases, file format conversion.
//
// This class gathers that logic.  It offers factory methods
// for attachments that do the necessary work. 
//
// The return value for the factory methods will be nil if the input is nil.
//
// [SignalAttachment hasError] will be true for non-valid attachments.
//
// TODO: Perhaps do conversion off the main thread?
@objc
public class SignalAttachment: NSObject {

    // MARK: Properties

    @objc
    public let dataSource: DataSource

    @objc
    public var captionText: String?

    @objc
    public var data: Data {
        return dataSource.data
    }

    @objc
    public var dataLength: UInt {
        return dataSource.dataLength
    }

    @objc
    public var dataUrl: URL? {
        return dataSource.dataUrl
    }

    @objc
    public var sourceFilename: String? {
        return dataSource.sourceFilename?.filterFilename()
    }

    @objc
    public var isValidImage: Bool {
        return dataSource.isValidImage
    }

    @objc
    public var isValidVideo: Bool {
        return dataSource.isValidVideo
    }

    // This flag should be set for text attachments that can be sent as text messages.
    @objc
    public var isConvertibleToTextMessage = false

    // This flag should be set for attachments that can be sent as contact shares.
    @objc
    public var isConvertibleToContactShare = false

    // This flag should be set for attachments that should be sent as view-once messages.
    @objc
    public var isViewOnceAttachment = false

    // Attachment types are identified using UTIs.
    //
    // See: https://developer.apple.com/library/content/documentation/Miscellaneous/Reference/UTIRef/Articles/System-DeclaredUniformTypeIdentifiers.html
    @objc
    public let dataUTI: String

    var error: SignalAttachmentError? {
        didSet {
            AssertIsOnMainThread()

            assert(oldValue == nil)
            Logger.verbose("Attachment has error: \(String(describing: error))")
        }
    }

    // To avoid redundant work of repeatedly compressing/uncompressing
    // images, we cache the UIImage associated with this attachment if
    // possible.
    private var cachedImage: UIImage?
    private var cachedVideoPreview: UIImage?

    @objc
    private(set) public var isVoiceMessage = false

    // MARK: Constants

    public static let kMaxFileSizeAnimatedImage = OWSMediaUtils.kMaxFileSizeAnimatedImage
    public static let kMaxFileSizeImage = OWSMediaUtils.kMaxFileSizeImage
    public static let kMaxFileSizeVideo = OWSMediaUtils.kMaxFileSizeVideo
    public static let kMaxFileSizeAudio = OWSMediaUtils.kMaxFileSizeAudio
    public static let kMaxFileSizeGeneric = OWSMediaUtils.kMaxFileSizeGeneric

    // MARK: 

    @objc
    public static let maxAttachmentsAllowed: Int = 32

    // MARK: Constructor

    // This method should not be called directly; use the factory
    // methods instead.
    @objc
    private init(dataSource: DataSource, dataUTI: String) {
        self.dataSource = dataSource
        self.dataUTI = dataUTI
        super.init()
    }

    // MARK: Methods

    @objc
    public var hasError: Bool {
        return error != nil
    }

    @objc
    public var errorName: String? {
        guard let error = error else {
            // This method should only be called if there is an error.
            owsFailDebug("Missing error")
            return nil
        }

        return "\(error)"
    }

    @objc
    public var localizedErrorDescription: String? {
        guard let error = self.error else {
            // This method should only be called if there is an error.
            owsFailDebug("Missing error")
            return nil
        }
        guard let errorDescription = error.errorDescription else {
            owsFailDebug("Missing error description")
            return nil
        }

        return "\(errorDescription)"
    }

    @objc
    public override var debugDescription: String {
        let fileSize = ByteCountFormatter.string(fromByteCount: Int64(dataLength), countStyle: .file)
        let string = "[SignalAttachment] mimeType: \(mimeType), fileSize: \(fileSize)"

        // Computing resolution from dataUrl could cause DataSourceValue to write to disk, which
        // can be expensive. Only do it in debug.
        #if DEBUG
        if let dataUrl = dataUrl {
            if isVideo {
                let resolution = OWSMediaUtils.videoResolution(url: dataUrl)
                return "\(string), resolution: \(resolution), aspectRatio: \(resolution.aspectRatio)"
            } else if isImage {
                let resolution = NSData.imageSize(forFilePath: dataUrl.path, mimeType: nil)
                return "\(string), resolution: \(resolution), aspectRatio: \(resolution.aspectRatio)"
            }
        }
        #endif

        return string
    }

    @objc
    public class var missingDataErrorMessage: String {
        guard let errorDescription = SignalAttachmentError.missingData.errorDescription else {
            owsFailDebug("Missing error description")
            return ""
        }
        return errorDescription
    }

    public func cloneAttachment() throws -> SignalAttachment {
        let sourceUrl = dataUrl!
        let newUrl = OWSFileSystem.temporaryFileUrl(fileExtension: sourceUrl.pathExtension)
        try FileManager.default.copyItem(at: sourceUrl, to: newUrl)

        let clonedDataSource = try DataSourcePath.dataSource(with: newUrl,
                                                             shouldDeleteOnDeallocation: true)
        clonedDataSource.sourceFilename = sourceFilename

        return self.replacingDataSource(with: clonedDataSource)
    }

    private func replacingDataSource(with newDataSource: DataSource, dataUTI: String? = nil) -> SignalAttachment {
        let result = SignalAttachment(dataSource: newDataSource, dataUTI: dataUTI ?? self.dataUTI)
        result.captionText = captionText
        result.isConvertibleToTextMessage = isConvertibleToTextMessage
        result.isConvertibleToContactShare = isConvertibleToContactShare
        result.isViewOnceAttachment = isViewOnceAttachment
        result.isVoiceMessage = isVoiceMessage
        result.isBorderless = isBorderless
        return result
    }

    @objc
    public func buildOutgoingAttachmentInfo(message: TSMessage) -> OutgoingAttachmentInfo {
        return OutgoingAttachmentInfo(dataSource: dataSource,
                                      contentType: mimeType,
                                      sourceFilename: filenameOrDefault,
                                      caption: captionText,
                                      albumMessageId: message.uniqueId,
                                      isBorderless: isBorderless)
    }

    @objc
    public func staticThumbnail() -> UIImage? {
        if isAnimatedImage {
            return image()
        } else if isImage {
            return image()
        } else if isVideo {
            return videoPreview()
        } else if isAudio {
            return nil
        } else {
            return nil
        }
    }

    @objc
    public func image() -> UIImage? {
        if let cachedImage = cachedImage {
            return cachedImage
        }
        guard let image = UIImage(data: dataSource.data) else {
            return nil
        }
        cachedImage = image
        return image
    }

    @objc
    public func videoPreview() -> UIImage? {
        if let cachedVideoPreview = cachedVideoPreview {
            return cachedVideoPreview
        }

        guard let mediaUrl = dataUrl else {
            return nil
        }

        do {
            let filePath = mediaUrl.path
            guard FileManager.default.fileExists(atPath: filePath) else {
                owsFailDebug("asset at \(filePath) doesn't exist")
                return nil
            }

            let asset = AVURLAsset(url: mediaUrl)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let cgImage = try generator.copyCGImage(at: CMTimeMake(value: 0, timescale: 1), actualTime: nil)
            let image = UIImage(cgImage: cgImage)

            cachedVideoPreview = image
            return image

        } catch let error {
            Logger.verbose("Could not generate video thumbnail: \(error.localizedDescription)")
            return nil
        }
    }

    @objc
    public var isBorderless = false

    // Returns the MIME type for this attachment or nil if no MIME type
    // can be identified.
    @objc
    public var mimeType: String {
        if isVoiceMessage {
            // Legacy iOS clients don't handle "audio/mp4" files correctly;
            // they are written to disk as .mp4 instead of .m4a which breaks
            // playback.  So we send voice messages as "audio/aac" to work
            // around this.
            //
            // TODO: Remove this Nov. 2016 or after.
            return "audio/aac"
        }

        if let filename = sourceFilename {
            let fileExtension = (filename as NSString).pathExtension
            if fileExtension.count > 0 {
                if let mimeType = MIMETypeUtil.mimeType(forFileExtension: fileExtension) {
                    // UTI types are an imperfect means of representing file type;
                    // file extensions are also imperfect but far more reliable and
                    // comprehensive so we always prefer to try to deduce MIME type
                    // from the file extension.
                    return mimeType
                }
            }
        }
        if isOversizeText {
            return OWSMimeTypeOversizeTextMessage
        }
        if dataUTI == kUnknownTestAttachmentUTI {
            return OWSMimeTypeUnknownForTests
        }
        guard let mimeType = UTTypeCopyPreferredTagWithClass(dataUTI as CFString, kUTTagClassMIMEType) else {
            return OWSMimeTypeApplicationOctetStream
        }
        return mimeType.takeRetainedValue() as String
    }

    // Use the filename if known. If not, e.g. if the attachment was copy/pasted, we'll generate a filename
    // like: "signal-2017-04-24-095918.zip"
    @objc
    public var filenameOrDefault: String {
        if let filename = sourceFilename {
            return filename.filterFilename()
        } else {
            let kDefaultAttachmentName = "signal"

            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "YYYY-MM-dd-HHmmss"
            let dateString = dateFormatter.string(from: Date())

            let withoutExtension = "\(kDefaultAttachmentName)-\(dateString)"
            if let fileExtension = self.fileExtension {
                return "\(withoutExtension).\(fileExtension)"
            }

            return withoutExtension
        }
    }

    // Returns the file extension for this attachment or nil if no file extension
    // can be identified.
    @objc
    public var fileExtension: String? {
        if let filename = sourceFilename {
            let fileExtension = (filename as NSString).pathExtension
            if fileExtension.count > 0 {
                return fileExtension.filterFilename()
            }
        }
        if isOversizeText {
            return kOversizeTextAttachmentFileExtension
        }
        if dataUTI == kUnknownTestAttachmentUTI {
            return "unknown"
        }
        guard let fileExtension = MIMETypeUtil.fileExtension(forUTIType: dataUTI) else {
            return nil
        }
        return fileExtension
    }

    // Returns the set of UTIs that correspond to valid _input_ image formats
    // for Signal attachments.
    //
    // Image attachments may be converted to another image format before 
    // being uploaded.
    private class var inputImageUTISet: Set<String> {
         // HEIC is valid input, but not valid output. Non-iOS11 clients do not support it.
        let heicSet: Set<String> = Set(["public.heic", "public.heif"])

        return MIMETypeUtil.supportedInputImageUTITypes()
            .union(animatedImageUTISet)
            .union(heicSet)
    }

    // Returns the set of UTIs that correspond to valid _output_ image formats
    // for Signal attachments.
    private class var outputImageUTISet: Set<String> {
        return MIMETypeUtil.supportedOutputImageUTITypes().union(animatedImageUTISet)
    }

    private class var outputVideoUTISet: Set<String> {
        return Set([kUTTypeMPEG4 as String])
    }

    // Returns the set of UTIs that correspond to valid animated image formats
    // for Signal attachments.
    private class var animatedImageUTISet: Set<String> {
        return MIMETypeUtil.supportedAnimatedImageUTITypes()
    }

    // Returns the set of UTIs that correspond to valid video formats
    // for Signal attachments.
    private class var videoUTISet: Set<String> {
        return MIMETypeUtil.supportedVideoUTITypes()
    }

    // Returns the set of UTIs that correspond to valid audio formats
    // for Signal attachments.
    private class var audioUTISet: Set<String> {
        return MIMETypeUtil.supportedAudioUTITypes()
    }

    // Returns the set of UTIs that correspond to valid image, video and audio formats
    // for Signal attachments.
    private class var mediaUTISet: Set<String> {
        return audioUTISet.union(videoUTISet).union(animatedImageUTISet).union(inputImageUTISet)
    }

    @objc
    public var isImage: Bool {
        return SignalAttachment.outputImageUTISet.contains(dataUTI)
    }

    @objc
    public var isAnimatedImage: Bool {
        if dataUTI == (kUTTypePNG as String),
            dataSource.imageMetadata.isAnimated {
            return true
        }

        return SignalAttachment.animatedImageUTISet.contains(dataUTI)
    }

    @objc
    public var isVideo: Bool {
        return SignalAttachment.videoUTISet.contains(dataUTI)
    }

    @objc
    public var isAudio: Bool {
        return SignalAttachment.audioUTISet.contains(dataUTI)
    }

    @objc
    public var isOversizeText: Bool {
        return dataUTI == kOversizeTextAttachmentUTI
    }

    @objc
    public var isText: Bool {
        return UTTypeConformsTo(dataUTI as CFString, kUTTypeText) || isOversizeText
    }

    @objc
    public var isUrl: Bool {
        return UTTypeConformsTo(dataUTI as CFString, kUTTypeURL)
    }

    @objc
    public class func pasteboardHasPossibleAttachment() -> Bool {
        return UIPasteboard.general.numberOfItems > 0
    }

    @objc
    public class func pasteboardHasText() -> Bool {
        if UIPasteboard.general.numberOfItems < 1 {
            return false
        }
        let itemSet = IndexSet(integer: 0)
        guard let pasteboardUTITypes = UIPasteboard.general.types(forItemSet: itemSet) else {
            return false
        }
        let pasteboardUTISet = Set<String>(filterDynamicUTITypes(pasteboardUTITypes[0]))
        guard pasteboardUTISet.count > 0 else {
            return false
        }

        // The mention text view has a special pasteboard type, if we see it
        // we know that the pasteboard contains text.
        guard !pasteboardUTISet.contains(MentionTextView.pasteboardType) else {
            return true
        }

        // The pasteboard can be populated with multiple UTI types
        // with different payloads.  iMessage for example will copy
        // an animated GIF to the pasteboard with the following UTI
        // types:
        //
        // * "public.url-name"
        // * "public.utf8-plain-text"
        // * "com.compuserve.gif"
        //
        // We want to paste the animated GIF itself, not it's name.
        //
        // In general, our rule is to prefer non-text pasteboard
        // contents, so we return true IFF there is a text UTI type
        // and there is no non-text UTI type.
        var hasTextUTIType = false
        var hasNonTextUTIType = false
        for utiType in pasteboardUTISet {
            if UTTypeConformsTo(utiType as CFString, kUTTypeText) {
                hasTextUTIType = true
            } else if mediaUTISet.contains(utiType) {
                hasNonTextUTIType = true
            }
        }
        if pasteboardUTISet.contains(kUTTypeURL as String) {
            // Treat URL as a textual UTI type.
            hasTextUTIType = true
        }
        if hasNonTextUTIType {
            return false
        }
        return hasTextUTIType
    }

    // Discard "dynamic" UTI types since our attachment pipeline
    // requires "standard" UTI types to work properly, e.g. when
    // mapping between UTI type, MIME type and file extension.
    private class func filterDynamicUTITypes(_ types: [String]) -> [String] {
        return types.filter {
            !$0.hasPrefix("dyn")
        }
    }

    // Returns an attachment from the pasteboard, or nil if no attachment
    // can be found.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    @objc
    public class func attachmentFromPasteboard() -> SignalAttachment? {
        guard UIPasteboard.general.numberOfItems >= 1 else {
            return nil
        }

        // If pasteboard contains multiple items, use only the first.
        let itemSet = IndexSet(integer: 0)
        guard let pasteboardUTITypes = UIPasteboard.general.types(forItemSet: itemSet) else {
            return nil
        }

        var pasteboardUTISet = Set<String>(filterDynamicUTITypes(pasteboardUTITypes[0]))
        guard pasteboardUTISet.count > 0 else {
            return nil
        }

        // If we have the choice between a png and a jpg, always choose
        // the png as it may have transparency. Apple provides both jpg
        //  and png uti types when sending memoji stickers and
        // `inputImageUTISet` is unordered, so without this check there
        // is a 50/50 chance that we'd pick the jpg.
        if pasteboardUTISet.isSuperset(of: [kUTTypeJPEG as String, kUTTypePNG as String]) {
            pasteboardUTISet.remove(kUTTypeJPEG as String)
        }

        for dataUTI in inputImageUTISet {
            if pasteboardUTISet.contains(dataUTI) {
                guard let data = dataForFirstPasteboardItem(dataUTI: dataUTI) else {
                    owsFailDebug("Missing expected pasteboard data for UTI: \(dataUTI)")
                    return nil
                }
                let dataSource = DataSourceValue.dataSource(with: data, utiType: dataUTI)

                // If the data source is sticker like AND we're pasting the attachment,
                // we want to make it borderless.
                let isBorderless = dataSource?.hasStickerLikeProperties ?? false

                return imageAttachment(dataSource: dataSource, dataUTI: dataUTI, imageQuality: .medium, isBorderless: isBorderless)
            }
        }
        for dataUTI in videoUTISet {
            if pasteboardUTISet.contains(dataUTI) {
                guard let data = dataForFirstPasteboardItem(dataUTI: dataUTI) else {
                    owsFailDebug("Missing expected pasteboard data for UTI: \(dataUTI)")
                    return nil
                }
                let dataSource = DataSourceValue.dataSource(with: data, utiType: dataUTI)
                return videoAttachment(dataSource: dataSource, dataUTI: dataUTI)
            }
        }
        for dataUTI in audioUTISet {
            if pasteboardUTISet.contains(dataUTI) {
                guard let data = dataForFirstPasteboardItem(dataUTI: dataUTI) else {
                    owsFailDebug("Missing expected pasteboard data for UTI: \(dataUTI)")
                    return nil
                }
                let dataSource = DataSourceValue.dataSource(with: data, utiType: dataUTI)
                return audioAttachment(dataSource: dataSource, dataUTI: dataUTI)
            }
        }

        let dataUTI = pasteboardUTISet[pasteboardUTISet.startIndex]
        guard let data = dataForFirstPasteboardItem(dataUTI: dataUTI) else {
            owsFailDebug("Missing expected pasteboard data for UTI: \(dataUTI)")
            return nil
        }
        let dataSource = DataSourceValue.dataSource(with: data, utiType: dataUTI)
        return genericAttachment(dataSource: dataSource, dataUTI: dataUTI)
    }

    // This method should only be called for dataUTIs that
    // are appropriate for the first pasteboard item.
    private class func dataForFirstPasteboardItem(dataUTI: String) -> Data? {
        let itemSet = IndexSet(integer: 0)
        guard let datas = UIPasteboard.general.data(forPasteboardType: dataUTI, inItemSet: itemSet) else {
            owsFailDebug("Missing expected pasteboard data for UTI: \(dataUTI)")
            return nil
        }
        guard let data = datas.first else {
            owsFailDebug("Missing expected pasteboard data for UTI: \(dataUTI)")
            return nil
        }
        return data
    }

    // MARK: Image Attachments

    // Factory method for an image attachment.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    @objc
    private class func imageAttachment(dataSource: DataSource?, dataUTI: String, imageQuality: TSImageQuality, isBorderless: Bool = false) -> SignalAttachment {
        assert(dataUTI.count > 0)
        assert(dataSource != nil)
        guard let dataSource = dataSource else {
            let attachment = SignalAttachment(dataSource: DataSourceValue.emptyDataSource(), dataUTI: dataUTI)
            attachment.error = .missingData
            return attachment
        }

        let attachment = SignalAttachment(dataSource: dataSource, dataUTI: dataUTI)

        attachment.isBorderless = isBorderless

        guard inputImageUTISet.contains(dataUTI) else {
            attachment.error = .invalidFileFormat
            return attachment
        }

        guard dataSource.dataLength > 0 else {
            owsFailDebug("imageData was empty")
            attachment.error = .invalidData
            return attachment
        }

        let imageMetadata = dataSource.imageMetadata
        let isAnimated = imageMetadata.isAnimated
        if isAnimated {
            guard dataSource.dataLength <= kMaxFileSizeAnimatedImage else {
                attachment.error = .fileSizeTooLarge
                return attachment
            }

            // Never re-encode animated images (i.e. GIFs) as JPEGs.
            Logger.verbose("Sending raw \(attachment.mimeType) to retain any animation")
            return attachment
        } else {
            let imageClass = (dataSource.data as NSData).isMaybeWebpData ? YYImage.self : UIImage.self
            guard let image = imageClass.init(data: dataSource.data) else {
                attachment.error = .couldNotParseImage
                return attachment
            }
            attachment.cachedImage = image

            if let sourceFilename = dataSource.sourceFilename,
                let sourceFileExtension = sourceFilename.fileExtension,
                ["heic", "heif"].contains(sourceFileExtension.lowercased()),
                dataUTI == kUTTypeJPEG as String {

                // If a .heic file actually contains jpeg data, update the extension to match.
                //
                // Here's how that can happen:
                // In iOS11, the Photos.app records photos with HEIC UTIType, with the .HEIC extension.
                // Since HEIC isn't a valid output format for Signal, we'll detect that and convert to JPEG,
                // updating the extension as well. No problem.
                // However the problem comes in when you edit an HEIC image in Photos.app - the image is saved
                // in the Photos.app as a JPEG, but retains the (now incongruous) HEIC extension in the filename.
                Logger.verbose("changing extension: \(sourceFileExtension) to match jpg uti type")

                let baseFilename = sourceFilename.filenameWithoutExtension
                dataSource.sourceFilename = baseFilename.appendingFileExtension("jpg")
            }

            if isValidOutputOriginalImage(dataSource: dataSource, dataUTI: dataUTI, imageQuality: imageQuality) {
                Logger.verbose("Rewriting attachment with metadata removed \(attachment.mimeType)")
                do {
                    return try attachment.removingImageMetadata()
                } catch {
                    Logger.verbose("Failed to remove metadata directly: \(error)")
                }
            }

            let size = ByteCountFormatter.string(fromByteCount: Int64(dataSource.dataLength), countStyle: .file)
            Logger.verbose("Rebuilding image attachment of type: \(attachment.mimeType), size: \(size)")

            return convertAndCompressImage(image: image,
                                           attachment: attachment,
                                           filename: dataSource.sourceFilename,
                                           imageQuality: imageQuality)
        }
    }

    // If the proposed attachment already conforms to the
    // file size and content size limits, don't recompress it.
    private class func isValidOutputOriginalImage(dataSource: DataSource,
                                                  dataUTI: String,
                                                  imageQuality: TSImageQuality) -> Bool {
        guard SignalAttachment.outputImageUTISet.contains(dataUTI) else {
            return false
        }
        if !doesImageHaveAcceptableFileSize(dataSource: dataSource, imageQuality: imageQuality) {
            return false
        }
        if imageQuality == .original || dataSource.hasStickerLikeProperties {
            return true
        }
        return false
    }

    private class func convertAndCompressImage(image: UIImage, attachment: SignalAttachment, filename: String?, imageQuality: TSImageQuality) -> SignalAttachment {
        assert(attachment.error == nil)

        var imageUploadQuality = imageQuality.imageQualityTier()

        while true {
            let outcome = convertAndCompressImageAttempt(image: image,
                                                         attachment: attachment,
                                                         filename: filename,
                                                         imageQuality: imageQuality,
                                                         imageUploadQuality: imageUploadQuality)
            switch outcome {
            case .signalAttachment(let signalAttachment):
                return signalAttachment
            case .error(let error):
                attachment.error = error
                return attachment
            case .reduceQuality(let imageQualityTier):
                imageUploadQuality = imageQualityTier
            }
        }
    }

    private enum ConvertAndCompressOutcome {
        case signalAttachment(signalAttachment: SignalAttachment)
        case reduceQuality(imageQualityTier: TSImageQualityTier)
        case error(error: SignalAttachmentError)
    }

    private class func convertAndCompressImageAttempt(image: UIImage,
                                                      attachment: SignalAttachment,
                                                      filename: String?,
                                                      imageQuality: TSImageQuality,
                                                      imageUploadQuality: TSImageQualityTier) -> ConvertAndCompressOutcome {
        autoreleasepool {  () -> ConvertAndCompressOutcome in
            owsAssertDebug(attachment.error == nil)

            let maxSize = maxSizeForImage(image: image, imageUploadQuality: imageUploadQuality)
            var dstImage: UIImage! = image
            if image.size.width > maxSize ||
                image.size.height > maxSize {
                guard let resizedImage = imageScaled(image, toMaxSize: maxSize) else {
                    return .error(error: .couldNotResizeImage)
                }
                dstImage = resizedImage
            }

            let dataUTI: String
            let dataMIMEType: String
            let dataFileExtension: String
            let imageData: Data

            if image.cgImage?.hasAlpha == true {
                guard let pngImageData = dstImage.pngData() else {
                    return .error(error: .couldNotConvertImage)
                }

                dataUTI = kUTTypePNG as String
                dataMIMEType = OWSMimeTypeImagePng
                dataFileExtension = "png"
                imageData = pngImageData
            } else {
                guard let jpgImageData = dstImage.jpegData(
                    compressionQuality: jpegCompressionQuality(imageUploadQuality: imageUploadQuality)
                ) else {
                    return .error(error: .couldNotConvertImage)
                }

                dataUTI = kUTTypeJPEG as String
                dataMIMEType = OWSMimeTypeImageJpeg
                dataFileExtension = "jpg"
                imageData = jpgImageData
            }

            let dataSource: DataSource
            do {
                let tempFileUrl = OWSFileSystem.temporaryFileUrl(fileExtension: dataFileExtension)
                try imageData.write(to: tempFileUrl)
                dataSource = try DataSourcePath.dataSource(with: tempFileUrl, shouldDeleteOnDeallocation: false)
            } catch {
                return .error(error: .couldNotConvertImage)
            }

            let baseFilename = filename?.filenameWithoutExtension
            let newFilenameWithExtension = baseFilename?.appendingFileExtension(dataFileExtension)
            dataSource.sourceFilename = newFilenameWithExtension

            if doesImageHaveAcceptableFileSize(dataSource: dataSource, imageQuality: imageQuality) &&
                dataSource.dataLength <= kMaxFileSizeImage {
                let recompressedAttachment = attachment.replacingDataSource(with: dataSource, dataUTI: dataUTI)
                recompressedAttachment.cachedImage = dstImage
                Logger.verbose("Converted \(attachment.mimeType), size: \(dataSource.dataLength) to \(ByteCountFormatter.string(fromByteCount: Int64(imageData.count), countStyle: .file)) \(dataMIMEType)")
                return .signalAttachment(signalAttachment: recompressedAttachment)
            }

            // If the image output is larger than the file size limit,
            // continue to try again by progressively reducing the
            // image upload quality.
            switch imageUploadQuality {
            case .original:
                return .reduceQuality(imageQualityTier: .high)
            case .high:
                return .reduceQuality(imageQualityTier: .mediumHigh)
            case .mediumHigh:
                return .reduceQuality(imageQualityTier: .medium)
            case .medium:
                return .reduceQuality(imageQualityTier: .mediumLow)
            case .mediumLow:
                return .reduceQuality(imageQualityTier: .low)
            case .low:
                return .error(error: .fileSizeTooLarge)
            }
        }
    }

    // NOTE: For unknown reasons, resizing images with UIGraphicsBeginImageContext()
    // crashes reliably in the share extension after screen lock's auth UI has been presented.
    // Resizing using a CGContext seems to work fine.
    private class func imageScaled(_ uiImage: UIImage, toMaxSize maxSize: CGFloat) -> UIImage? {
        autoreleasepool {
            Logger.verbose("maxSize: \(maxSize)")
            guard let cgImage = uiImage.cgImage else {
                owsFailDebug("UIImage missing cgImage.")
                return nil
            }

            // It's essential that we work consistently in "CG" coordinates (which are
            // pixels and don't reflect orientation), not "UI" coordinates (which
            // are points and do reflect orientation).
            let scrSize = CGSize(width: cgImage.width, height: cgImage.height)
            var maxSizeRect = CGRect.zero
            maxSizeRect.size = CGSize(square: maxSize)
            let newSize = AVMakeRect(aspectRatio: scrSize, insideRect: maxSizeRect).size.floor
            assert(newSize.width <= maxSize)
            assert(newSize.height <= maxSize)

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo: CGBitmapInfo = [
                CGBitmapInfo(rawValue: CGImageByteOrderInfo.orderDefault.rawValue),
                CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)]
            guard let context = CGContext(data: nil,
                                          width: Int(newSize.width),
                                          height: Int(newSize.height),
                                          bitsPerComponent: 8,
                                          bytesPerRow: 0,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo.rawValue) else {
                owsFailDebug("could not create CGContext.")
                return nil
            }
            context.interpolationQuality = .high

            var drawRect = CGRect.zero
            drawRect.size = newSize
            context.draw(cgImage, in: drawRect)

            guard let newCGImage = context.makeImage() else {
                owsFailDebug("could not create new CGImage.")
                return nil
            }
            return UIImage(cgImage: newCGImage,
                           scale: uiImage.scale,
                           orientation: uiImage.imageOrientation)
        }
    }

    private class func doesImageHaveAcceptableFileSize(dataSource: DataSource, imageQuality: TSImageQuality) -> Bool {
        switch imageQuality {
        case .original:
            // This deliberately checks against "generic" rather than "image" for files attached as documents.
            return dataSource.dataLength < kMaxFileSizeGeneric
        case .medium:
            return dataSource.dataLength < UInt(1024 * 1024)
        case .compact:
            return dataSource.dataLength < UInt(400 * 1024)
        }
    }

    private class func maxSizeForImage(image: UIImage, imageUploadQuality: TSImageQualityTier) -> CGFloat {
        switch imageUploadQuality {
        case .original:
            return max(image.size.width, image.size.height)
        case .high:
            return 2048
        case .mediumHigh:
            return 1536
        case .medium:
            return 1024
        case .mediumLow:
            return 768
        case .low:
            return 512
        }
    }

    private class func jpegCompressionQuality(imageUploadQuality: TSImageQualityTier) -> CGFloat {
        // 0.6 produces some artifacting but not a ton.
        // We don't want to scale this level down across qualities because lower resolutions show artifacting more.
        return 0.6
    }

    private static let preservedMetadata: [CFString] = [
        "\(kCGImageMetadataPrefixTIFF):\(kCGImagePropertyTIFFOrientation)" as CFString,
        "\(kCGImageMetadataPrefixIPTCCore):\(kCGImagePropertyIPTCImageOrientation)" as CFString
    ]

    private func removingImageMetadata() throws -> SignalAttachment {
        owsAssertDebug(isImage)

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw SignalAttachmentError.missingData
        }

        guard let type = CGImageSourceGetType(source) else {
            throw SignalAttachmentError.invalidFileFormat
        }

        let count = CGImageSourceGetCount(source)
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData as CFMutableData, type, count, nil) else {
            throw SignalAttachmentError.couldNotRemoveMetadata
        }

        // Build up a metadata with CFNulls in the place of all tags present in the original metadata.
        // (Unfortunately CGImageDestinationCopyImageSource can only merge metadata, not replace it.)
        let metadata = CGImageMetadataCreateMutable()
        let enumerateOptions: NSDictionary = [kCGImageMetadataEnumerateRecursively: false]
        var hadError = false
        for i in 0..<count {
            guard let originalMetadata = CGImageSourceCopyMetadataAtIndex(source, i, nil) else {
                throw SignalAttachmentError.couldNotRemoveMetadata
            }
            CGImageMetadataEnumerateTagsUsingBlock(originalMetadata, nil, enumerateOptions) { path, tag in
                if Self.preservedMetadata.contains(path) {
                    return true
                }
                guard let namespace = CGImageMetadataTagCopyNamespace(tag),
                      let prefix = CGImageMetadataTagCopyPrefix(tag),
                      CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace, prefix, nil),
                      CGImageMetadataSetValueWithPath(metadata, nil, path, kCFNull) else {
                    hadError = true
                    return false // stop iteration
                }
                return true
            }
            if hadError {
                throw SignalAttachmentError.couldNotRemoveMetadata
            }
        }

        var error: Unmanaged<CFError>?
        let copyOptions: NSDictionary = [
            kCGImageDestinationMergeMetadata: true,
            kCGImageDestinationMetadata: metadata
        ]
        guard CGImageDestinationCopyImageSource(destination, source, copyOptions, &error) else {
            let errorMessage = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "(unknown error)"
            Logger.verbose("CGImageDestinationCopyImageSource failed for \(dataUTI): \(errorMessage)")
            throw SignalAttachmentError.couldNotRemoveMetadata
        }

        guard let dataSource = DataSourceValue.dataSource(with: mutableData as Data, utiType: dataUTI) else {
            throw SignalAttachmentError.couldNotRemoveMetadata
        }

        return self.replacingDataSource(with: dataSource)
    }

    // MARK: Video Attachments

    // Factory method for video attachments.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    private class func videoAttachment(dataSource: DataSource?, dataUTI: String) -> SignalAttachment {
        guard let dataSource = dataSource else {
            let dataSource = DataSourceValue.emptyDataSource()
            let attachment = SignalAttachment(dataSource: dataSource, dataUTI: dataUTI)
            attachment.error = .missingData
            return attachment
        }

        if !isValidOutputVideo(dataSource: dataSource, dataUTI: dataUTI) {
            owsFailDebug("building video with invalid output, migrate to async API using compressVideoAsMp4")
        }

        return newAttachment(dataSource: dataSource,
                             dataUTI: dataUTI,
                             validUTISet: videoUTISet,
                             maxFileSize: kMaxFileSizeVideo)
    }

    public class func copyToVideoTempDir(url fromUrl: URL) throws -> URL {
        let baseDir = SignalAttachment.videoTempPath.appendingPathComponent(UUID().uuidString, isDirectory: true)
        OWSFileSystem.ensureDirectoryExists(baseDir.path)
        let toUrl = baseDir.appendingPathComponent(fromUrl.lastPathComponent)

        Logger.debug("moving \(fromUrl) -> \(toUrl)")
        try FileManager.default.copyItem(at: fromUrl, to: toUrl)

        return toUrl
    }

    private class var videoTempPath: URL {
        let videoDir = URL(fileURLWithPath: OWSTemporaryDirectory()).appendingPathComponent("video")
        OWSFileSystem.ensureDirectoryExists(videoDir.path)
        return videoDir
    }

    public class func compressVideoAsMp4(dataSource: DataSource, dataUTI: String) -> (Promise<SignalAttachment>, AVAssetExportSession?) {
        Logger.debug("")

        guard let url = dataSource.dataUrl else {
            let attachment = SignalAttachment(dataSource: DataSourceValue.emptyDataSource(), dataUTI: dataUTI)
            attachment.error = .missingData
            return (Promise.value(attachment), nil)
        }

        return compressVideoAsMp4(asset: AVAsset(url: url), baseFilename: dataSource.sourceFilename, dataUTI: dataUTI)
    }

    public class func compressVideoAsMp4(asset: AVAsset, baseFilename: String?, dataUTI: String) -> (Promise<SignalAttachment>, AVAssetExportSession?) {
        Logger.debug("")
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset640x480) else {
            let attachment = SignalAttachment(dataSource: DataSourceValue.emptyDataSource(), dataUTI: dataUTI)
            attachment.error = .couldNotConvertToMpeg4
            return (Promise.value(attachment), nil)
        }

        exportSession.shouldOptimizeForNetworkUse = true
        exportSession.outputFileType = AVFileType.mp4
        exportSession.metadataItemFilter = AVMetadataItemFilter.forSharing()

        let exportURL = videoTempPath.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        exportSession.outputURL = exportURL

        let (promise, resolver) = Promise<SignalAttachment>.pending()

        Logger.debug("starting video export")
        exportSession.exportAsynchronously {
            Logger.debug("Completed video export")
            let mp4Filename = baseFilename?.filenameWithoutExtension.appendingFileExtension("mp4")

            do {
                let dataSource = try DataSourcePath.dataSource(with: exportURL,
                                                               shouldDeleteOnDeallocation: true)
                dataSource.sourceFilename = mp4Filename

                let attachment = SignalAttachment(dataSource: dataSource, dataUTI: kUTTypeMPEG4 as String)
                resolver.fulfill(attachment)
            } catch {
                owsFailDebug("Failed to build data source for exported video URL")
                let attachment = SignalAttachment(dataSource: DataSourceValue.emptyDataSource(), dataUTI: dataUTI)
                attachment.error = .couldNotConvertToMpeg4
                resolver.fulfill(attachment)
                return
            }
        }

        return (promise, exportSession)
    }

    @objc
    public class VideoCompressionResult: NSObject {
        @objc
        public let attachmentPromise: AnyPromise

        @objc
        public let exportSession: AVAssetExportSession?

        fileprivate init(attachmentPromise: Promise<SignalAttachment>, exportSession: AVAssetExportSession?) {
            self.attachmentPromise = AnyPromise(attachmentPromise)
            self.exportSession = exportSession
            super.init()
        }
    }

    @objc
    public class func compressVideoAsMp4(dataSource: DataSource, dataUTI: String) -> VideoCompressionResult {
        let (attachmentPromise, exportSession) = compressVideoAsMp4(dataSource: dataSource, dataUTI: dataUTI)
        return VideoCompressionResult(attachmentPromise: attachmentPromise, exportSession: exportSession)
    }

    @objc
    public class func isVideoThatNeedsCompression(dataSource: DataSource, dataUTI: String) -> Bool {
        guard videoUTISet.contains(dataUTI) else {
            // not a video
            return false
        }

        // Today we re-encode all videos for the most consistent experience.
        return true
    }

    private class func isValidOutputVideo(dataSource: DataSource?, dataUTI: String) -> Bool {
        guard let dataSource = dataSource else {
            Logger.warn("Missing dataSource.")
            return false
        }

        guard SignalAttachment.outputVideoUTISet.contains(dataUTI) else {
            Logger.warn("Invalid UTI type: \(dataUTI).")
            return false
        }

        if dataSource.dataLength <= kMaxFileSizeVideo {
            return true
        }
        Logger.verbose("Invalid file size: \(dataSource.dataLength) > \(kMaxFileSizeVideo).")
        Logger.warn("Invalid file size.")
        return false
    }

    // MARK: Audio Attachments

    // Factory method for audio attachments.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    private class func audioAttachment(dataSource: DataSource?, dataUTI: String) -> SignalAttachment {
        return newAttachment(dataSource: dataSource,
                             dataUTI: dataUTI,
                             validUTISet: audioUTISet,
                             maxFileSize: kMaxFileSizeAudio)
    }

    // MARK: Oversize Text Attachments

    // Factory method for oversize text attachments.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    private class func oversizeTextAttachment(text: String?) -> SignalAttachment {
        let dataSource = DataSourceValue.dataSource(withOversizeText: text)
        return newAttachment(dataSource: dataSource,
                             dataUTI: kOversizeTextAttachmentUTI,
                             validUTISet: nil,
                             maxFileSize: kMaxFileSizeGeneric)
    }

    // MARK: Generic Attachments

    // Factory method for generic attachments.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    private class func genericAttachment(dataSource: DataSource?, dataUTI: String) -> SignalAttachment {
        return newAttachment(dataSource: dataSource,
                             dataUTI: dataUTI,
                             validUTISet: nil,
                             maxFileSize: kMaxFileSizeGeneric)
    }

    // MARK: Voice Messages

    @objc
    public class func voiceMessageAttachment(dataSource: DataSource?, dataUTI: String) -> SignalAttachment {
        let attachment = audioAttachment(dataSource: dataSource, dataUTI: dataUTI)
        attachment.isVoiceMessage = true
        return attachment
    }

    // MARK: Attachments

    // Factory method for non-image Attachments.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    @objc
    public class func attachment(dataSource: DataSource?, dataUTI: String) -> SignalAttachment {
        if inputImageUTISet.contains(dataUTI) {
            owsFailDebug("must specify image quality type")
        }
        return attachment(dataSource: dataSource, dataUTI: dataUTI, imageQuality: .original)
    }

    // Factory method for attachments of any kind.
    //
    // NOTE: The attachment returned by this method may not be valid.
    //       Check the attachment's error property.
    @objc
    public class func attachment(dataSource: DataSource?, dataUTI: String, imageQuality: TSImageQuality) -> SignalAttachment {
        if inputImageUTISet.contains(dataUTI) {
            return imageAttachment(dataSource: dataSource, dataUTI: dataUTI, imageQuality: imageQuality)
        } else if videoUTISet.contains(dataUTI) {
            return videoAttachment(dataSource: dataSource, dataUTI: dataUTI)
        } else if audioUTISet.contains(dataUTI) {
            return audioAttachment(dataSource: dataSource, dataUTI: dataUTI)
        } else {
            return genericAttachment(dataSource: dataSource, dataUTI: dataUTI)
        }
    }

    @objc
    public class func empty() -> SignalAttachment {
        return SignalAttachment.attachment(dataSource: DataSourceValue.emptyDataSource(),
                                           dataUTI: kUTTypeContent as String,
                                           imageQuality: .original)
    }

    // MARK: Helper Methods

    private class func newAttachment(dataSource: DataSource?,
                                     dataUTI: String,
                                     validUTISet: Set<String>?,
                                     maxFileSize: UInt) -> SignalAttachment {
        assert(dataUTI.count > 0)

        assert(dataSource != nil)
        guard let dataSource = dataSource else {
            let attachment = SignalAttachment(dataSource: DataSourceValue.emptyDataSource(), dataUTI: dataUTI)
            attachment.error = .missingData
            return attachment
        }

        let attachment = SignalAttachment(dataSource: dataSource, dataUTI: dataUTI)

        if let validUTISet = validUTISet {
            guard validUTISet.contains(dataUTI) else {
                attachment.error = .invalidFileFormat
                return attachment
            }
        }

        guard dataSource.dataLength > 0 else {
            owsFailDebug("Empty attachment")
            assert(dataSource.dataLength > 0)
            attachment.error = .invalidData
            return attachment
        }

        guard dataSource.dataLength <= maxFileSize else {
            attachment.error = .fileSizeTooLarge
            return attachment
        }

        // Attachment is valid
        return attachment
    }
}
