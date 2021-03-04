//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

#import "OWSUploadOperation.h"
#import "MIMETypeUtil.h"
#import "NSError+OWSOperation.h"
#import "NSNotificationCenter+OWS.h"
#import "OWSDispatch.h"
#import "OWSError.h"
#import "OWSOperation.h"
#import "OWSRequestFactory.h"
#import "OWSUpload.h"
#import "SSKEnvironment.h"
#import "TSAttachmentStream.h"
#import "TSNetworkManager.h"
#import <PromiseKit/AnyPromise.h>
#import <SignalCoreKit/Cryptography.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSString *const kAttachmentUploadProgressNotification = @"kAttachmentUploadProgressNotification";
NSString *const kAttachmentUploadProgressKey = @"kAttachmentUploadProgressKey";
NSString *const kAttachmentUploadAttachmentIDKey = @"kAttachmentUploadAttachmentIDKey";

@interface OWSUploadOperation ()

@property (readonly, nonatomic) NSString *attachmentId;
@property (readonly, nonatomic) BOOL canUseV3;
@property (readonly, nonatomic) NSArray<NSString *> *messageIds;

@property (nonatomic, nullable) TSAttachmentStream *completedUpload;

@end

#pragma mark -

@implementation OWSUploadOperation

#pragma mark - Dependencies

- (SDSDatabaseStorage *)databaseStorage
{
    return SDSDatabaseStorage.shared;
}

+ (NSOperationQueue *)uploadQueue
{
    static NSOperationQueue *operationQueue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        operationQueue = [NSOperationQueue new];
        operationQueue.name = @"Uploads";

        // TODO - stream uploads from file and raise this limit.
        operationQueue.maxConcurrentOperationCount = 1;
    });

    return operationQueue;
}

#pragma mark -

- (instancetype)initWithAttachmentId:(NSString *)attachmentId
                          messageIds:(NSArray<NSString *> *)messageIds
                            canUseV3:(BOOL)canUseV3
{
    self = [super init];
    if (!self) {
        return self;
    }

    self.remainingRetries = 4;

    _attachmentId = attachmentId;
    _canUseV3 = canUseV3;
    _messageIds = messageIds;

    return self;
}

- (TSNetworkManager *)networkManager
{
    return SSKEnvironment.shared.networkManager;
}

- (void)run
{
    __block TSAttachmentStream *_Nullable attachmentStream;
    [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
        attachmentStream =
            [TSAttachmentStream anyFetchAttachmentStreamWithUniqueId:self.attachmentId transaction:transaction];
        if (attachmentStream == nil) {
            // Message may have been removed.
            OWSLogWarn(@"Missing attachment.");
            return;
        }
    }];

    if (!attachmentStream) {
        OWSProdError([OWSAnalyticsEvents messageSenderErrorCouldNotLoadAttachment]);
        NSError *error = OWSErrorMakeFailedToSendOutgoingMessageError();
        // Not finding local attachment is a terminal failure.
        error.isRetryable = NO;
        [self reportError:error];
        return;
    }

    if (attachmentStream.isUploaded) {
        OWSLogDebug(@"Attachment previously uploaded.");
        self.completedUpload = attachmentStream;
        [self reportSuccess];
        return;
    }
    
    [self fireNotificationWithProgress:0];

    OWSAttachmentUploadV2 *upload = [[OWSAttachmentUploadV2 alloc] initWithAttachmentStream:attachmentStream
                                                                                   canUseV3:self.canUseV3];
    [BlurHash ensureBlurHashForAttachmentStream:attachmentStream]
        .catchInBackground(^{
            // Swallow these errors; blurHashes are strictly optional.
            OWSLogWarn(@"Error generating blurHash.");
        })
        .thenInBackground(^{
            return [upload uploadWithProgressBlock:^(
                NSProgress *uploadProgress) { [self fireNotificationWithProgress:uploadProgress.fractionCompleted]; }];
        })
        .thenInBackground(^{
            DatabaseStorageWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
                [attachmentStream updateAsUploadedWithEncryptionKey:upload.encryptionKey
                                                             digest:upload.digest
                                                           serverId:upload.serverId
                                                             cdnKey:upload.cdnKey
                                                          cdnNumber:upload.cdnNumber
                                                    uploadTimestamp:upload.uploadTimestamp
                                                        transaction:transaction];

                for (NSString *messageId in self.messageIds) {
                    TSInteraction *_Nullable interaction = [TSInteraction anyFetchWithUniqueId:messageId
                                                                                   transaction:transaction];
                    if (interaction == nil) {
                        OWSLogWarn(@"Missing interaction.");
                        continue;
                    }
                    [self.databaseStorage touchInteraction:interaction shouldReindex:false transaction:transaction];
                }
            });
            self.completedUpload = attachmentStream;
            [self reportSuccess];
        })
        .catchInBackground(^(NSError *error) {
            OWSLogError(@"Failed: %@", error);

            if (HTTPStatusCodeForError(error).intValue == 413) {
                OWSFailDebug(@"Request entity too large: %@.", @(attachmentStream.byteCount));
                error.isRetryable = NO;
            } else if (error.code == kCFURLErrorSecureConnectionFailed) {
                error.isRetryable = NO;
            } else {
                error.isRetryable = YES;
            }

            [self reportError:error];
        });
}

- (void)fireNotificationWithProgress:(CGFloat)progress
{
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];

    [notificationCenter postNotificationNameAsync:kAttachmentUploadProgressNotification
                                           object:nil
                                         userInfo:@{
                                             kAttachmentUploadProgressKey : @(progress),
                                             kAttachmentUploadAttachmentIDKey : self.attachmentId
                                         }];
}

@end

NS_ASSUME_NONNULL_END
