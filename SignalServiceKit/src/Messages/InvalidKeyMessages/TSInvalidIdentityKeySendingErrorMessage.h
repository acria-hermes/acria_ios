//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

#import "TSInvalidIdentityKeyErrorMessage.h"

NS_ASSUME_NONNULL_BEGIN

@class PreKeyBundle;
@class TSOutgoingMessage;
@class TSThread;

// DEPRECATED - we no longer create new instances of this class (as of  mid-2017); However, existing instances may
// exist, so we should keep this class around to honor their old behavior.
__attribute__((deprecated)) @interface TSInvalidIdentityKeySendingErrorMessage : TSInvalidIdentityKeyErrorMessage

@property (nonatomic, readonly) NSString *messageId;

- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
             receivedAtTimestamp:(uint64_t)receivedAtTimestamp
                          sortId:(uint64_t)sortId
                       timestamp:(uint64_t)timestamp
                  uniqueThreadId:(NSString *)uniqueThreadId
                   attachmentIds:(NSArray<NSString *> *)attachmentIds
                            body:(nullable NSString *)body
                      bodyRanges:(nullable MessageBodyRanges *)bodyRanges
                    contactShare:(nullable OWSContact *)contactShare
                 expireStartedAt:(uint64_t)expireStartedAt
                       expiresAt:(uint64_t)expiresAt
                expiresInSeconds:(unsigned int)expiresInSeconds
              isViewOnceComplete:(BOOL)isViewOnceComplete
               isViewOnceMessage:(BOOL)isViewOnceMessage
                     linkPreview:(nullable OWSLinkPreview *)linkPreview
                  messageSticker:(nullable MessageSticker *)messageSticker
                   quotedMessage:(nullable TSQuotedMessage *)quotedMessage
    storedShouldStartExpireTimer:(BOOL)storedShouldStartExpireTimer
              wasRemotelyDeleted:(BOOL)wasRemotelyDeleted
                       errorType:(TSErrorMessageType)errorType
                            read:(BOOL)read
                recipientAddress:(nullable SignalServiceAddress *)recipientAddress
             wasIdentityVerified:(BOOL)wasIdentityVerified
                       messageId:(NSString *)messageId
                    preKeyBundle:(PreKeyBundle *)preKeyBundle
NS_DESIGNATED_INITIALIZER NS_SWIFT_NAME(init(grdbId:uniqueId:receivedAtTimestamp:sortId:timestamp:uniqueThreadId:attachmentIds:body:bodyRanges:contactShare:expireStartedAt:expiresAt:expiresInSeconds:isViewOnceComplete:isViewOnceMessage:linkPreview:messageSticker:quotedMessage:storedShouldStartExpireTimer:wasRemotelyDeleted:errorType:read:recipientAddress:wasIdentityVerified:messageId:preKeyBundle:));

// clang-format on

// --- CODE GENERATION MARKER

@end

NS_ASSUME_NONNULL_END