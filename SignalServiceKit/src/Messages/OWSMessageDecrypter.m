//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

#import "OWSMessageDecrypter.h"
#import "NSData+messagePadding.h"
#import "NotificationsProtocol.h"
#import "OWSAnalytics.h"
#import "OWSBlockingManager.h"
#import "OWSDevice.h"
#import "OWSError.h"
#import "OWSIdentityManager.h"
#import "OWSOutgoingNullMessage.h"
#import "SSKEnvironment.h"
#import "SSKPreKeyStore.h"
#import "SSKSignedPreKeyStore.h"
#import "SignalRecipient.h"
#import "TSAccountManager.h"
#import "TSContactThread.h"
#import "TSErrorMessage.h"
#import "TSPreKeyManager.h"
#import <SignalCoreKit/NSData+OWS.h>
#import <SignalCoreKit/NSString+OWS.h>
#import <SignalCoreKit/Randomness.h>
#import <SignalCoreKit/SCKExceptionWrapper.h>
#import <SignalMetadataKit/SignalMetadataKit-Swift.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

NS_ASSUME_NONNULL_BEGIN

NSError *EnsureDecryptError(NSError *_Nullable error, NSString *fallbackErrorDescription)
{
    if (error) {
        return error;
    }
    OWSCFailDebug(@"Caller should provide specific error");
    return OWSErrorWithCodeDescription(OWSErrorCodeFailedToDecryptUDMessage, fallbackErrorDescription);
}

#pragma mark -

@interface OWSMessageDecryptResult ()

@property (nonatomic) NSData *envelopeData;
@property (nonatomic, nullable) NSData *plaintextData;
@property (nonatomic) SignalServiceAddress *sourceAddress;
@property (nonatomic) UInt32 sourceDevice;
@property (nonatomic) BOOL isUDMessage;

@end

#pragma mark -

@implementation OWSMessageDecryptResult

+ (OWSMessageDecryptResult *)resultWithEnvelopeData:(NSData *)envelopeData
                                      plaintextData:(nullable NSData *)plaintextData
                                      sourceAddress:(SignalServiceAddress *)sourceAddress
                                       sourceDevice:(UInt32)sourceDevice
                                        isUDMessage:(BOOL)isUDMessage
{
    OWSAssertDebug(envelopeData);
    OWSAssertDebug(sourceAddress.isValid);
    OWSAssertDebug(sourceDevice > 0);

    OWSMessageDecryptResult *result = [OWSMessageDecryptResult new];
    result.envelopeData = envelopeData;
    result.plaintextData = plaintextData;
    result.sourceAddress = sourceAddress;
    result.sourceDevice = sourceDevice;
    result.isUDMessage = isUDMessage;
    return result;
}

@end

#pragma mark -

@interface OWSMessageDecrypter ()

@property (atomic, readonly) NSMutableSet *senderIdsResetDuringCurrentBatch;

@end

@interface OWSMessageDecrypter (ImplementedInSwift)
+ (BOOL)decryptEnvelope:(SSKProtoEnvelope *)envelope
           envelopeData:(NSData *)envelopeData
             cipherType:(CipherMessageType)cipherType
 recentlyResetSenderIds:(NSMutableSet *)senderIdsResetDuringCurrentBatch
           successBlock:(DecryptSuccessBlock)successBlock
           failureBlock:(void(^)(NSError *))error;

+ (NSError *)processError:(NSError *)error
                 envelope:(SSKProtoEnvelope *)envelope
   recentlyResetSenderIds:(NSMutableSet *)senderIdsResetDuringCurrentBatch;

+ (BOOL)isSignalClientError:(NSError *)error;
+ (BOOL)isSecretSessionSelfSentMessageError:(NSError *)error;
@end

@implementation OWSMessageDecrypter

- (instancetype)init
{
    self = [super init];

    if (!self) {
        return self;
    }

    OWSSingletonAssert();

    _senderIdsResetDuringCurrentBatch = [NSMutableSet new];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(messageDecryptJobQueueDidFlush)
                                                 name:kNSNotificationNameMessageDecryptionDidFlushQueue
                                               object:nil];

    return self;
}

#pragma mark - Dependencies

- (OWSBlockingManager *)blockingManager
{
    OWSAssertDebug(SSKEnvironment.shared.blockingManager);

    return SSKEnvironment.shared.blockingManager;
}

- (OWSIdentityManager *)identityManager
{
    OWSAssertDebug(SSKEnvironment.shared.identityManager);

    return SSKEnvironment.shared.identityManager;
}

- (id<OWSUDManager>)udManager
{
    OWSAssertDebug(SSKEnvironment.shared.udManager);

    return SSKEnvironment.shared.udManager;
}

- (TSAccountManager *)tsAccountManager
{
    OWSAssertDebug(SSKEnvironment.shared.tsAccountManager);
    
    return SSKEnvironment.shared.tsAccountManager;
}

- (SDSDatabaseStorage *)databaseStorage
{
    return SDSDatabaseStorage.shared;
}

- (SSKSessionStore *)sessionStore
{
    return SSKEnvironment.shared.sessionStore;
}

- (SSKPreKeyStore *)preKeyStore
{
    return SSKEnvironment.shared.preKeyStore;
}

- (SSKSignedPreKeyStore *)signedPreKeyStore
{
    return SSKEnvironment.shared.signedPreKeyStore;
}

- (MessageSender *)messageSender
{
    OWSAssertDebug(SSKEnvironment.shared.messageSender);

    return SSKEnvironment.shared.messageSender;
}

- (MessageProcessing *)messageProcessing
{
    return SSKEnvironment.shared.messageProcessing;
}

#pragma mark - Blocking

- (BOOL)isEnvelopeSenderBlocked:(SSKProtoEnvelope *)envelope
{
    OWSAssertDebug(envelope);

    return [self.blockingManager isAddressBlocked:envelope.sourceAddress];
}

#pragma mark - Decryption

- (void)messageDecryptJobQueueDidFlush
{
    // We don't want to send additional resets until we
    // have received the "empty" response from the WebSocket
    // or finished at least one REST fetch.
    if (!self.messageProcessing.hasCompletedInitialFetch) {
        return;
    }

    // We clear all recently reset sender ids any time the
    // decryption queue has drained, so that any new messages
    // that fail to decrypt will reset the session again.
    [self.senderIdsResetDuringCurrentBatch removeAllObjects];
}

- (void)decryptEnvelope:(SSKProtoEnvelope *)envelope
           envelopeData:(NSData *)envelopeData
           successBlock:(DecryptSuccessBlock)successBlockParameter
           failureBlock:(DecryptFailureBlock)failureBlockParameter
{
    OWSAssertDebug(envelope);
    OWSAssertDebug(envelopeData);
    OWSAssertDebug(successBlockParameter);
    OWSAssertDebug(failureBlockParameter);
    OWSAssertDebug([self.tsAccountManager isRegistered]);

    // successBlock is called synchronously so that we can avail ourselves of
    // the transaction.
    //
    // Ensure that failureBlock is called on a worker queue.
    DecryptFailureBlock failureBlock = ^() {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            failureBlockParameter();
        });
    };

    uint32_t localDeviceId = self.tsAccountManager.storedDeviceId;
    DecryptSuccessBlock successBlock = ^(OWSMessageDecryptResult *result, SDSAnyWriteTransaction *transaction) {
        // Ensure all blocked messages are discarded.
        if ([self isEnvelopeSenderBlocked:envelope]) {
            OWSLogInfo(@"Ignoring blocked envelope: %@", envelope.sourceAddress);
            return failureBlock();
        }

        if (result.sourceAddress.isLocalAddress && result.sourceDevice == localDeviceId) {
            // Self-sent messages should be discarded during the decryption process.
            OWSFailDebug(@"Unexpected self-sent sync message.");
            return failureBlock();
        }

        // Having received a valid (decryptable) message from this user,
        // make note of the fact that they have a valid Signal account.
        [SignalRecipient markRecipientAsRegisteredAndGet:result.sourceAddress
                                                deviceId:result.sourceDevice
                                              trustLevel:SignalRecipientTrustLevelHigh
                                             transaction:transaction];

        successBlockParameter(result, transaction);
    };

    @try {
        OWSLogInfo(@"decrypting envelope: %@", [self descriptionForEnvelope:envelope]);

        if (!envelope.hasType) {
            OWSFailDebug(@"Incoming envelope is missing type.");
            return failureBlock();
        }
        if (![SDS fitsInInt64:envelope.timestamp]) {
            OWSFailDebug(@"Invalid timestamp.");
            return failureBlock();
        }
        if (envelope.hasServerTimestamp && ![SDS fitsInInt64:envelope.serverTimestamp]) {
            OWSFailDebug(@"Invalid serverTimestamp.");
            return failureBlock();
        }

        if (envelope.unwrappedType != SSKProtoEnvelopeTypeUnidentifiedSender) {
            if (!envelope.hasValidSource) {
                OWSFailDebug(@"incoming envelope has invalid source");
                return failureBlock();
            }

            if (!envelope.hasSourceDevice || envelope.sourceDevice < 1) {
                OWSFailDebug(@"incoming envelope has invalid source device");
                return failureBlock();
            }

            // We block UD messages later, after they are decrypted.
            if ([self isEnvelopeSenderBlocked:envelope]) {
                OWSLogInfo(@"ignoring blocked envelope: %@", envelope.sourceAddress);
                return failureBlock();
            }
        }

        switch (envelope.unwrappedType) {
            case SSKProtoEnvelopeTypeCiphertext: {
                [self throws_decryptSecureMessage:envelope
                    envelopeData:envelopeData
                    successBlock:^(OWSMessageDecryptResult *result, SDSAnyWriteTransaction *transaction) {
                        OWSLogDebug(@"decrypted secure message.");
                        successBlock(result, transaction);
                    }
                    failureBlock:^(NSError *_Nullable error) {
                        OWSLogError(@"decrypting secure message from address: %@ failed with error: %@",
                            envelopeAddress(envelope),
                            error);
                        OWSProdError([OWSAnalyticsEvents messageManagerErrorCouldNotHandleSecureMessage]);
                        failureBlock();
                    }];
                // Return to avoid double-acknowledging.
                return;
            }
            case SSKProtoEnvelopeTypePrekeyBundle: {
                [self throws_decryptPreKeyBundle:envelope
                    envelopeData:envelopeData
                    successBlock:^(OWSMessageDecryptResult *result, SDSAnyWriteTransaction *transaction) {
                        OWSLogDebug(@"decrypted pre-key whisper message");
                        successBlock(result, transaction);
                    }
                    failureBlock:^(NSError *_Nullable error) {
                        OWSLogError(@"decrypting pre-key whisper message from address: %@ failed "
                                    @"with error: %@",
                            envelopeAddress(envelope),
                            error);
                        OWSProdError([OWSAnalyticsEvents messageManagerErrorCouldNotHandlePrekeyBundle]);
                        failureBlock();
                    }];
                // Return to avoid double-acknowledging.
                return;
            }
            // These message types don't have a payload to decrypt.
            case SSKProtoEnvelopeTypeReceipt:
            case SSKProtoEnvelopeTypeKeyExchange:
            case SSKProtoEnvelopeTypeUnknown: {
                DatabaseStorageWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
                    OWSMessageDecryptResult *result =
                        [OWSMessageDecryptResult resultWithEnvelopeData:envelopeData
                                                          plaintextData:nil
                                                          sourceAddress:envelope.sourceAddress
                                                           sourceDevice:envelope.sourceDevice
                                                            isUDMessage:NO];
                    successBlock(result, transaction);
                });
                // Return to avoid double-acknowledging.
                return;
            }
            case SSKProtoEnvelopeTypeUnidentifiedSender: {
                [self decryptUnidentifiedSender:envelope
                    successBlock:^(OWSMessageDecryptResult *result, SDSAnyWriteTransaction *transaction) {
                        OWSLogDebug(@"decrypted unidentified sender message");
                        successBlock(result, transaction);
                    }
                    failureBlock:^(NSError *_Nullable error) {
                        if (error.code != OWSErrorCodeFailedToDecryptDuplicateMessage) {
                            OWSLogError(@"decrypting unidentified sender message from address: %@ failed "
                                        @"with error: %@",
                                envelopeAddress(envelope),
                                error);
                            OWSProdError(
                                [OWSAnalyticsEvents messageManagerErrorCouldNotHandleUnidentifiedSenderMessage]);
                        }
                        failureBlock();
                    }];
                // Return to avoid double-acknowledging.
                return;
            }
            default:
                OWSLogWarn(@"Received unhandled envelope type: %d", (int)envelope.unwrappedType);
                break;
        }
    } @catch (NSException *exception) {
        OWSFailDebug(@"Received an invalid envelope: %@", exception.debugDescription);
        OWSProdFail([OWSAnalyticsEvents messageManagerErrorInvalidProtocolMessage]);

        DatabaseStorageWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
            ThreadlessErrorMessage *errorMessage = [ThreadlessErrorMessage corruptedMessageInUnknownThread];
            [SSKEnvironment.shared.notificationsManager notifyUserForThreadlessErrorMessage:errorMessage
                                                                                transaction:transaction];
        });
    }

    failureBlock();
}

- (void)throws_decryptSecureMessage:(SSKProtoEnvelope *)envelope
                       envelopeData:(NSData *)envelopeData
                       successBlock:(DecryptSuccessBlock)successBlock
                       failureBlock:(void (^)(NSError *_Nullable error))failureBlock
{
    OWSAssertDebug(envelope);
    OWSAssertDebug(envelopeData);
    OWSAssertDebug(successBlock);
    OWSAssertDebug(failureBlock);

    [self decryptEnvelope:envelope
             envelopeData:envelopeData
               cipherType:CipherMessageType_Whisper
             successBlock:successBlock
             failureBlock:failureBlock];
}

- (void)throws_decryptPreKeyBundle:(SSKProtoEnvelope *)envelope
                      envelopeData:(NSData *)envelopeData
                      successBlock:(DecryptSuccessBlock)successBlock
                      failureBlock:(void (^)(NSError *_Nullable error))failureBlock
{
    OWSAssertDebug(envelope);
    OWSAssertDebug(envelopeData);
    OWSAssertDebug(successBlock);
    OWSAssertDebug(failureBlock);

    // Check whether we need to refresh our PreKeys every time we receive a PreKeyWhisperMessage.
    [TSPreKeyManager checkPreKeysIfNecessary];

    [self decryptEnvelope:envelope
             envelopeData:envelopeData
               cipherType:CipherMessageType_Prekey
             successBlock:successBlock
             failureBlock:failureBlock];
}

- (void)decryptEnvelope:(SSKProtoEnvelope *)envelope
           envelopeData:(NSData *)envelopeData
             cipherType:(CipherMessageType)cipherType
           successBlock:(DecryptSuccessBlock)successBlock
           failureBlock:(void (^)(NSError *))failureBlock
{
    [[self class] decryptEnvelope:envelope
                     envelopeData:envelopeData
                       cipherType:cipherType
           recentlyResetSenderIds:self.senderIdsResetDuringCurrentBatch
                     successBlock:successBlock
                     failureBlock:failureBlock];
}

- (void)decryptUnidentifiedSender:(SSKProtoEnvelope *)envelope
                     successBlock:(DecryptSuccessBlock)successBlock
                     failureBlock:(void (^)(NSError *_Nullable error))failureBlock
{
    OWSAssertDebug(envelope);
    OWSAssertDebug(successBlock);
    OWSAssertDebug(failureBlock);

    // NOTE: We don't need to bother with `legacyMessage` for UD messages.
    NSData *encryptedData = envelope.content;
    if (!encryptedData) {
        NSString *errorDescription = @"UD Envelope is missing content.";
        OWSFailDebug(@"%@", errorDescription);
        NSError *error = OWSErrorWithCodeDescription(OWSErrorCodeFailedToDecryptUDMessage, errorDescription);
        return failureBlock(error);
    }

    if (!envelope.hasServerTimestamp) {
        NSString *errorDescription = @"UD Envelope is missing server timestamp.";
        // TODO: We're seeing incoming UD envelopes without a server timestamp on staging.
        // Until this is fixed, disabling this assert.
        //        OWSFailDebug(@"%@", errorDescription);
        OWSLogError(@"%@", errorDescription);
        NSError *error = OWSErrorWithCodeDescription(OWSErrorCodeFailedToDecryptUDMessage, errorDescription);
        return failureBlock(error);
    }
    UInt64 serverTimestamp = envelope.serverTimestamp;
    if (![SDS fitsInInt64:serverTimestamp]) {
        NSString *errorDescription = @"Invalid serverTimestamp.";
        OWSFailDebug(@"%@", errorDescription);
        NSError *error = OWSErrorWithCodeDescription(OWSErrorCodeFailedToDecryptUDMessage, errorDescription);
        return failureBlock(error);
    }

    id<SMKCertificateValidator> certificateValidator =
        [[SMKCertificateDefaultValidator alloc] initWithTrustRoot:self.udManager.trustRoot];

    SignalServiceAddress *localAddress = self.tsAccountManager.localAddress;
    uint32_t localDeviceId = self.tsAccountManager.storedDeviceId;

    DatabaseStorageAsyncWrite(self.databaseStorage, ^(SDSAnyWriteTransaction *transaction) {
        [self decryptUnidentifiedSender:envelope
                          encryptedData:encryptedData
                   certificateValidator:certificateValidator
                           localAddress:localAddress
                          localDeviceId:localDeviceId
                        serverTimestamp:serverTimestamp
                            transaction:transaction
                           successBlock:successBlock
                           failureBlock:failureBlock];
    });
}

- (void)decryptUnidentifiedSender:(SSKProtoEnvelope *)envelope
                    encryptedData:(NSData *)encryptedData
             certificateValidator:(id<SMKCertificateValidator>)certificateValidator
                     localAddress:(SignalServiceAddress *)localAddress
                    localDeviceId:(uint32_t)localDeviceId
                  serverTimestamp:(UInt64)serverTimestamp
                      transaction:(SDSAnyWriteTransaction *)transaction
                     successBlock:(DecryptSuccessBlock)successBlock
                     failureBlock:(void (^)(NSError *_Nullable error))failureBlock
{
    NSError *cipherError;
    SMKSecretSessionCipher *_Nullable cipher =
        [[SMKSecretSessionCipher alloc] initWithSessionStore:self.sessionStore
                                                 preKeyStore:self.preKeyStore
                                           signedPreKeyStore:self.signedPreKeyStore
                                               identityStore:self.identityManager
                                                       error:&cipherError];
    if (cipherError || !cipher) {
        OWSFailDebug(@"Could not create secret session cipher: %@", cipherError);
        cipherError = EnsureDecryptError(cipherError, @"Could not create secret session cipher");
        return failureBlock(cipherError);
    }

    NSError *decryptError;
    SMKDecryptResult *_Nullable decryptResult =
        [cipher throwswrapped_decryptMessageWithCertificateValidator:certificateValidator
                                                      cipherTextData:encryptedData
                                                           timestamp:serverTimestamp
                                                           localE164:localAddress.phoneNumber
                                                           localUuid:localAddress.uuid
                                                       localDeviceId:localDeviceId
                                                     protocolContext:transaction
                                                               error:&decryptError];

    if (!decryptResult) {
        if (!decryptError) {
            OWSFailDebug(@"Caller should provide specific error");
            NSError *error
                = OWSErrorWithCodeDescription(OWSErrorCodeFailedToDecryptUDMessage, @"Could not decrypt UD message");
            return failureBlock(error);
        }

        // Decrypt Failure Part 1: Unwrap failure details

        NSError *_Nullable underlyingError;
        SSKProtoEnvelope *_Nullable identifiedEnvelope;

        if (![decryptError.domain isEqualToString:@"SignalMetadataKit.SecretSessionKnownSenderError"]) {
            underlyingError = decryptError;
            identifiedEnvelope = envelope;
        } else {
            underlyingError = decryptError.userInfo[NSUnderlyingErrorKey];

            NSString *_Nullable senderE164 = decryptError.userInfo[SecretSessionKnownSenderError.kSenderE164Key];
            NSUUID *_Nullable senderUuid = decryptError.userInfo[SecretSessionKnownSenderError.kSenderUuidKey];
            SignalServiceAddress *senderAddress =
                [[SignalServiceAddress alloc] initWithUuid:senderUuid
                                               phoneNumber:senderE164
                                                trustLevel:SignalRecipientTrustLevelHigh];
            OWSAssert(senderAddress.isValid);

            NSNumber *senderDeviceId = decryptError.userInfo[SecretSessionKnownSenderError.kSenderDeviceIdKey];
            OWSAssert(senderDeviceId);

            SSKProtoEnvelopeBuilder *identifiedEnvelopeBuilder = envelope.asBuilder;
            identifiedEnvelopeBuilder.sourceE164 = senderAddress.phoneNumber;
            identifiedEnvelopeBuilder.sourceUuid = senderAddress.uuidString;
            identifiedEnvelopeBuilder.sourceDevice = senderDeviceId.unsignedIntValue;
            NSError *identifiedEnvelopeBuilderError;

            identifiedEnvelope = [identifiedEnvelopeBuilder buildAndReturnError:&identifiedEnvelopeBuilderError];
            if (identifiedEnvelopeBuilderError) {
                OWSFailDebug(@"failure identifiedEnvelopeBuilderError: %@", identifiedEnvelopeBuilderError);
            }
        }
        OWSAssert(underlyingError);
        OWSAssert(identifiedEnvelope);

        // Decrypt Failure Part 2: Handle unwrapped failure details

        if ([[self class] isSignalClientError:underlyingError]) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSError *wrappedError = [[self class] processError:underlyingError
                                                          envelope:identifiedEnvelope
                                            recentlyResetSenderIds:self.senderIdsResetDuringCurrentBatch];
                failureBlock(wrappedError);
            });
            return;
        }

        if ([[self class] isSecretSessionSelfSentMessageError:underlyingError]) {
            // Self-sent messages can be safely discarded.
            failureBlock(underlyingError);
            return;
        }

        OWSFailDebug(@"Could not decrypt UD message: %@", underlyingError);
        failureBlock(underlyingError);
        return;
    }

    if (decryptResult.messageType == SMKMessageTypePrekey) {
        [TSPreKeyManager checkPreKeysIfNecessary];
    }

    NSString *_Nullable senderE164 = decryptResult.senderE164;
    NSUUID *_Nullable senderUuid = decryptResult.senderUuid;
    SignalServiceAddress *sourceAddress = [[SignalServiceAddress alloc] initWithUuid:senderUuid
                                                                         phoneNumber:senderE164
                                                                          trustLevel:SignalRecipientTrustLevelHigh];
    if (!sourceAddress.isValid) {
        NSString *errorDescription = [NSString stringWithFormat:@"Invalid UD sender: %@", sourceAddress];
        OWSFailDebug(@"%@", errorDescription);
        NSError *error = OWSErrorWithCodeDescription(OWSErrorCodeFailedToDecryptUDMessage, errorDescription);
        return failureBlock(error);
    }

    long sourceDeviceId = decryptResult.senderDeviceId;
    if (sourceDeviceId < 1 || sourceDeviceId > UINT32_MAX) {
        NSString *errorDescription = @"Invalid UD sender device id.";
        OWSFailDebug(@"%@", errorDescription);
        NSError *error = OWSErrorWithCodeDescription(OWSErrorCodeFailedToDecryptUDMessage, errorDescription);
        return failureBlock(error);
    }
    NSData *plaintextData = [decryptResult.paddedPayload removePadding];

    SSKProtoEnvelopeBuilder *envelopeBuilder = [envelope asBuilder];
    [envelopeBuilder setSourceE164:sourceAddress.phoneNumber];
    [envelopeBuilder setSourceUuid:sourceAddress.uuidString];
    [envelopeBuilder setSourceDevice:(uint32_t)sourceDeviceId];
    NSError *envelopeBuilderError;
    NSData *_Nullable newEnvelopeData = [envelopeBuilder buildSerializedDataAndReturnError:&envelopeBuilderError];
    if (envelopeBuilderError || !newEnvelopeData) {
        OWSFailDebug(@"Could not update UD envelope data: %@", envelopeBuilderError);
        NSError *error = EnsureDecryptError(envelopeBuilderError, @"Could not update UD envelope data");
        return failureBlock(error);
    }

    OWSMessageDecryptResult *result = [OWSMessageDecryptResult resultWithEnvelopeData:newEnvelopeData
                                                                        plaintextData:plaintextData
                                                                        sourceAddress:sourceAddress
                                                                         sourceDevice:(UInt32)sourceDeviceId
                                                                          isUDMessage:YES];
    successBlock(result, transaction);
}

@end

NS_ASSUME_NONNULL_END
