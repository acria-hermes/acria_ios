//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

#import "TSThread.h"
#import "OWSDisappearingMessagesConfiguration.h"
#import "OWSReadTracking.h"
#import "SSKEnvironment.h"
#import "TSAccountManager.h"
#import "TSIncomingMessage.h"
#import "TSInfoMessage.h"
#import "TSInteraction.h"
#import "TSInvalidIdentityKeyReceivingErrorMessage.h"
#import "TSOutgoingMessage.h"
#import <SignalCoreKit/Cryptography.h>
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalCoreKit/NSString+OWS.h>
#import <SignalServiceKit/AppReadiness.h>
#import <SignalServiceKit/SignalServiceKit-Swift.h>

@import Intents;

NS_ASSUME_NONNULL_BEGIN

BOOL IsNoteToSelfEnabled(void)
{
    return YES;
}

ConversationColorName const ConversationColorNameCrimson = @"red";
ConversationColorName const ConversationColorNameVermilion = @"orange";
ConversationColorName const ConversationColorNameBurlap = @"brown";
ConversationColorName const ConversationColorNameForest = @"green";
ConversationColorName const ConversationColorNameWintergreen = @"light_green";
ConversationColorName const ConversationColorNameTeal = @"teal";
ConversationColorName const ConversationColorNameBlue = @"blue";
ConversationColorName const ConversationColorNameIndigo = @"indigo";
ConversationColorName const ConversationColorNameViolet = @"purple";
ConversationColorName const ConversationColorNamePlum = @"pink";
ConversationColorName const ConversationColorNameTaupe = @"blue_grey";
ConversationColorName const ConversationColorNameSteel = @"grey";

ConversationColorName const ConversationColorNameDefault = ConversationColorNameSteel;

@interface TSThread ()

@property (nonatomic, nullable) NSDate *creationDate;
@property (nonatomic) BOOL isArchived;
@property (nonatomic) BOOL isMarkedUnread;

@property (nonatomic, copy, nullable) NSString *messageDraft;
@property (nonatomic, nullable) MessageBodyRanges *messageDraftBodyRanges;

@property (atomic, nullable) NSDate *mutedUntilDate;
@property (nonatomic) int64_t lastInteractionRowId;

@property (nonatomic) uint64_t lastVisibleSortIdObsolete;
@property (nonatomic) double lastVisibleSortIdOnScreenPercentageObsolete;

@property (nonatomic) TSThreadMentionNotificationMode mentionNotificationMode;

@end

#pragma mark -

@implementation TSThread

#pragma mark - Dependencies

- (TSAccountManager *)tsAccountManager
{
    OWSAssertDebug(SSKEnvironment.shared.tsAccountManager);

    return SSKEnvironment.shared.tsAccountManager;
}

- (ThreadReadCache *)threadReadCache
{
    return SSKEnvironment.shared.modelReadCaches.threadReadCache;
}

#pragma mark -

+ (NSString *)collection {
    return @"TSThread";
}

+ (BOOL)shouldBeIndexedForFTS
{
    return YES;
}

- (instancetype)init
{
    return [super init];
}

- (instancetype)initWithUniqueId:(NSString *)uniqueId
{
    self = [super initWithUniqueId:uniqueId];

    if (self) {
        _creationDate    = [NSDate date];
        _messageDraft    = nil;

        // This is overriden in TSContactThread to use the phone number when available
        // We can't use self.colorSeed here because the subclass hasn't done its
        // initializing work yet to set it up.
        _conversationColorName = [self.class stableColorNameForNewConversationWithString:uniqueId];
    }

    return self;
}

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
           conversationColorName:(ConversationColorName)conversationColorName
                    creationDate:(nullable NSDate *)creationDate
                      isArchived:(BOOL)isArchived
                  isMarkedUnread:(BOOL)isMarkedUnread
            lastInteractionRowId:(int64_t)lastInteractionRowId
       lastVisibleSortIdObsolete:(uint64_t)lastVisibleSortIdObsolete
lastVisibleSortIdOnScreenPercentageObsolete:(double)lastVisibleSortIdOnScreenPercentageObsolete
         mentionNotificationMode:(TSThreadMentionNotificationMode)mentionNotificationMode
                    messageDraft:(nullable NSString *)messageDraft
          messageDraftBodyRanges:(nullable MessageBodyRanges *)messageDraftBodyRanges
                  mutedUntilDate:(nullable NSDate *)mutedUntilDate
           shouldThreadBeVisible:(BOOL)shouldThreadBeVisible
{
    self = [super initWithGrdbId:grdbId
                        uniqueId:uniqueId];

    if (!self) {
        return self;
    }

    _conversationColorName = conversationColorName;
    _creationDate = creationDate;
    _isArchived = isArchived;
    _isMarkedUnread = isMarkedUnread;
    _lastInteractionRowId = lastInteractionRowId;
    _lastVisibleSortIdObsolete = lastVisibleSortIdObsolete;
    _lastVisibleSortIdOnScreenPercentageObsolete = lastVisibleSortIdOnScreenPercentageObsolete;
    _mentionNotificationMode = mentionNotificationMode;
    _messageDraft = messageDraft;
    _messageDraftBodyRanges = messageDraftBodyRanges;
    _mutedUntilDate = mutedUntilDate;
    _shouldThreadBeVisible = shouldThreadBeVisible;

    return self;
}

// clang-format on

// --- CODE GENERATION MARKER

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (!self) {
        return self;
    }

    // renamed `hasEverHadMessage` -> `shouldThreadBeVisible`
    if (!_shouldThreadBeVisible) {
        NSNumber *_Nullable legacy_hasEverHadMessage = [coder decodeObjectForKey:@"hasEverHadMessage"];

        if (legacy_hasEverHadMessage != nil) {
            _shouldThreadBeVisible = legacy_hasEverHadMessage.boolValue;
        }
    }

    if (_conversationColorName.length == 0) {
        ConversationColorName colorName = [self.class stableColorNameForLegacyConversationWithString:self.colorSeed];
        OWSAssertDebug(colorName);

        _conversationColorName = colorName;
    } else if (![[[self class] conversationColorNames] containsObject:_conversationColorName]) {
        // If we'd persisted a non-mapped color name
        ConversationColorName _Nullable mappedColorName = self.class.legacyConversationColorMap[_conversationColorName];

        if (!mappedColorName) {
            // We previously used the wrong values for the new colors, it's possible we persited them.
            // map them to the proper value
            mappedColorName = self.class.legacyFixupConversationColorMap[_conversationColorName];
        }

        if (!mappedColorName) {
            OWSFailDebug(@"failure: unexpected unmappable conversationColorName: %@", _conversationColorName);
            mappedColorName = ConversationColorNameDefault;
        }

        _conversationColorName = mappedColorName;
    }

    NSDate *_Nullable lastMessageDate = [coder decodeObjectOfClass:NSDate.class forKey:@"lastMessageDate"];
    NSDate *_Nullable archivalDate = [coder decodeObjectOfClass:NSDate.class forKey:@"archivalDate"];
    _isArchivedByLegacyTimestampForSorting =
        [self.class legacyIsArchivedWithLastMessageDate:lastMessageDate archivalDate:archivalDate];

    if ([coder decodeObjectForKey:@"archivedAsOfMessageSortId"] != nil) {
        OWSAssertDebug(!_isArchived);
        _isArchived = YES;
    }

    return self;
}

- (void)anyDidInsertWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [super anyDidInsertWithTransaction:transaction];

    if (self.shouldThreadBeVisible && ![SSKPreferences hasSavedThreadWithTransaction:transaction]) {
        [SSKPreferences setHasSavedThread:YES transaction:transaction];
    }

    [self.threadReadCache didInsertOrUpdateThread:self transaction:transaction];
}

- (void)anyDidUpdateWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [super anyDidUpdateWithTransaction:transaction];

    if (self.shouldThreadBeVisible && ![SSKPreferences hasSavedThreadWithTransaction:transaction]) {
        [SSKPreferences setHasSavedThread:YES transaction:transaction];
    }

    [self.threadReadCache didInsertOrUpdateThread:self transaction:transaction];

    [PinnedThreadManager handleUpdatedThread:self transaction:transaction];
}

- (void)anyDidRemoveWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [super anyDidRemoveWithTransaction:transaction];

    [self.threadReadCache didRemoveThread:self transaction:transaction];
}

- (void)anyWillRemoveWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [SDSDatabaseStorage.shared updateIdMappingWithThread:self transaction:transaction];

    [super anyWillRemoveWithTransaction:transaction];

    [self removeAllThreadInteractionsWithTransaction:transaction];

    // TODO: If we ever use transaction finalizations for more than
    // de-bouncing thread touches, we should promote this to TSYapDatabaseObject
    // (or at least include it in the "will remove" hook for any relevant models.
    [transaction addRemovedFinalizationKey:self.transactionFinalizationKey];
}

- (void)removeAllThreadInteractionsWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    // We can't safely delete interactions while enumerating them, so
    // we collect and delete separately.
    //
    // We don't want to instantiate the interactions when collecting them
    // or when deleting them.
    NSMutableArray<NSString *> *interactionIds = [NSMutableArray new];
    NSError *error;
    InteractionFinder *interactionFinder = [[InteractionFinder alloc] initWithThreadUniqueId:self.uniqueId];
    [interactionFinder enumerateInteractionIdsWithTransaction:transaction
                                                        error:&error
                                                        block:^(NSString *key, BOOL *stop) {
                                                            [interactionIds addObject:key];
                                                        }];
    if (error != nil) {
        OWSFailDebug(@"Error during enumeration: %@", error);
    }

    [transaction ignoreInteractionUpdatesForThreadUniqueId:self.uniqueId];
    
    for (NSString *interactionId in interactionIds) {
        // We need to fetch each interaction, since [TSInteraction removeWithTransaction:] does important work.
        TSInteraction *_Nullable interaction =
            [TSInteraction anyFetchWithUniqueId:interactionId transaction:transaction];
        if (!interaction) {
            OWSFailDebug(@"couldn't load thread's interaction for deletion.");
            continue;
        }
        [interaction anyRemoveWithTransaction:transaction];
    }

    // As an optimization, we called `ignoreInteractionUpdatesForThreadUniqueId` so as not
    // to re-save the thread after *each* interaction deletion. However, we still need to resave
    // the thread just once, after all the interactions are deleted.
    [self anyUpdateWithTransaction:transaction
                             block:^(TSThread *thread) {
                                 thread.lastInteractionRowId = 0;
                             }];
}

- (BOOL)isNoteToSelf
{
    return NO;
}

- (NSString *)colorSeed
{
    return self.uniqueId;
}

#pragma mark - To be subclassed.

- (NSArray<SignalServiceAddress *> *)recipientAddresses
{
    OWSAbstractMethod();

    return @[];
}

- (BOOL)hasSafetyNumbers
{
    return NO;
}

#pragma mark - Interactions

/**
 * Iterate over this thread's interactions
 */
- (void)enumerateRecentInteractionsWithTransaction:(SDSAnyReadTransaction *)transaction
                                        usingBlock:(void (^)(TSInteraction *interaction))block
{
    NSError *error;
    InteractionFinder *interactionFinder = [[InteractionFinder alloc] initWithThreadUniqueId:self.uniqueId];
    [interactionFinder enumerateRecentInteractionsWithTransaction:transaction
                                                            error:&error
                                                            block:^(TSInteraction *interaction, BOOL *stop) {
                                                                block(interaction);
                                                            }];
    if (error != nil) {
        OWSFailDebug(@"Error during enumeration: %@", error);
    }
}

/**
 * Enumerates all the threads interactions. Note this will explode if you try to create a transaction in the block.
 * If you need a transaction, use the sister method: `enumerateInteractionsWithTransaction:usingBlock`
 */
- (void)enumerateRecentInteractionsUsingBlock:(void (^)(TSInteraction *interaction))block
{
    [self.databaseStorage readWithBlock:^(SDSAnyReadTransaction *transaction) {
        [self enumerateRecentInteractionsWithTransaction:transaction
                                              usingBlock:^(TSInteraction *interaction) {
                                                  block(interaction);
                                              }];
    }];
}

/**
 * Useful for tests and debugging. In production use an enumeration method.
 */
- (NSArray<TSInteraction *> *)allInteractions
{
    NSMutableArray<TSInteraction *> *interactions = [NSMutableArray new];
    [self enumerateRecentInteractionsUsingBlock:^(TSInteraction *interaction) {
        [interactions addObject:interaction];
    }];

    return [interactions copy];
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (NSArray<TSInvalidIdentityKeyReceivingErrorMessage *> *)receivedMessagesForInvalidKey:(NSData *)key
{
    NSMutableArray *errorMessages = [NSMutableArray new];
    [self enumerateRecentInteractionsUsingBlock:^(TSInteraction *interaction) {
        if ([interaction isKindOfClass:[TSInvalidIdentityKeyReceivingErrorMessage class]]) {
            TSInvalidIdentityKeyReceivingErrorMessage *error = (TSInvalidIdentityKeyReceivingErrorMessage *)interaction;
            @try {
                if ([[error throws_newIdentityKey] isEqualToData:key]) {
                    [errorMessages addObject:(TSInvalidIdentityKeyReceivingErrorMessage *)interaction];
                }
            } @catch (NSException *exception) {
                OWSFailDebug(@"exception: %@", exception);
            }
        }
    }];

    return [errorMessages copy];
}
#pragma clang diagnostic pop

- (NSUInteger)numberOfInteractionsWithTransaction:(SDSAnyReadTransaction *)transaction
{
    OWSAssertDebug(transaction);
    return [[[InteractionFinder alloc] initWithThreadUniqueId:self.uniqueId] countWithTransaction:transaction];
}

- (void)markAllAsReadAndUpdateStorageService:(BOOL)updateStorageService
                                 transaction:(SDSAnyWriteTransaction *)transaction
{
    BOOL hasPendingMessageRequest = [self hasPendingMessageRequestWithTransaction:transaction.unwrapGrdbWrite];
    OWSReadCircumstance circumstance = hasPendingMessageRequest
        ? OWSReadCircumstanceReadOnThisDeviceWhilePendingMessageRequest
        : OWSReadCircumstanceReadOnThisDevice;

    InteractionFinder *interactionFinder = [[InteractionFinder alloc] initWithThreadUniqueId:self.uniqueId];

    for (id<OWSReadTracking> message in
        [interactionFinder allUnreadMessagesWithTransaction:transaction.unwrapGrdbRead]) {
        [message markAsReadAtTimestamp:[NSDate ows_millisecondTimeStamp]
                                thread:self
                          circumstance:circumstance
                           transaction:transaction];
    }

    [self clearMarkedAsUnreadAndUpdateStorageService:updateStorageService transaction:transaction];

    // Just to be defensive, we'll also check for unread messages.
    OWSAssertDebug([interactionFinder allUnreadMessagesWithTransaction:transaction.unwrapGrdbRead].count < 1);
}

- (void)clearMarkedAsUnreadAndUpdateStorageService:(BOOL)updateStorageService
                                       transaction:(SDSAnyWriteTransaction *)transaction
{
    __block BOOL wasMarkedUnread;
    [self anyUpdateWithTransaction:transaction
                             block:^(TSThread *thread) {
                                 wasMarkedUnread = thread.isMarkedUnread;
                                 thread.isMarkedUnread = NO;
                             }];

    if (updateStorageService && wasMarkedUnread) {
        [self recordPendingStorageServiceUpdates];
    }
}

- (void)markAsUnreadAndUpdateStorageService:(BOOL)updateStorageService transaction:(SDSAnyWriteTransaction *)transaction
{
    __block BOOL wasMarkedUnread;
    [self anyUpdateWithTransaction:transaction
                             block:^(TSThread *thread) {
                                 wasMarkedUnread = thread.isMarkedUnread;
                                 thread.isMarkedUnread = YES;
                             }];

    if (updateStorageService && !wasMarkedUnread) {
        [self recordPendingStorageServiceUpdates];
    }
}

- (nullable TSInteraction *)lastInteractionForInboxWithTransaction:(SDSAnyReadTransaction *)transaction
{
    OWSAssertDebug(transaction);
    return [[[InteractionFinder alloc] initWithThreadUniqueId:self.uniqueId]
        mostRecentInteractionForInboxWithTransaction:transaction];
}

- (nullable TSInteraction *)firstInteractionAtOrAroundSortId:(uint64_t)sortId
                                                 transaction:(SDSAnyReadTransaction *)transaction
{
    OWSAssertDebug(transaction);
    return
        [[[InteractionFinder alloc] initWithThreadUniqueId:self.uniqueId] firstInteractionAtOrAroundSortId:sortId
                                                                                               transaction:transaction];
}

- (void)updateWithInsertedMessage:(TSInteraction *)message transaction:(SDSAnyWriteTransaction *)transaction
{
    [self updateWithMessage:message wasMessageInserted:YES transaction:transaction];
}

- (void)updateWithUpdatedMessage:(TSInteraction *)message transaction:(SDSAnyWriteTransaction *)transaction
{
    [self updateWithMessage:message wasMessageInserted:NO transaction:transaction];
}

- (int64_t)messageSortIdForMessage:(TSInteraction *)message transaction:(SDSAnyWriteTransaction *)transaction
{
    if (transaction.transitional_yapWriteTransaction) {
        return message.sortId;
    } else {
        if (message.grdbId == nil) {
            OWSFailDebug(@"Missing messageSortId.");
        } else if (message.grdbId.unsignedLongLongValue == 0) {
            OWSFailDebug(@"Invalid messageSortId.");
        } else {
            return message.grdbId.longLongValue;
        }
    }
    return 0;
}

- (void)updateWithMessage:(TSInteraction *)message
       wasMessageInserted:(BOOL)wasMessageInserted
              transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(message != nil);
    OWSAssertDebug(transaction != nil);

    BOOL hasLastVisibleInteraction = [self hasLastVisibleInteractionWithTransaction:transaction];
    BOOL needsToClearLastVisibleSortId = hasLastVisibleInteraction && wasMessageInserted;

    if (![message shouldAppearInInboxWithTransaction:transaction]) {
        // We want to clear the last visible sort ID on any new message,
        // even if the message doesn't appear in the inbox view.
        if (needsToClearLastVisibleSortId) {
            [self clearLastVisibleInteractionWithTransaction:transaction];
        }

        return;
    }

    int64_t messageSortId = [self messageSortIdForMessage:message transaction:transaction];
    BOOL needsToMarkAsVisible = !self.shouldThreadBeVisible;

    BOOL needsToClearArchived = self.isArchived && wasMessageInserted;

    // Don't clear archived during migrations.
    if (!CurrentAppContext().isRunningTests && !AppReadiness.isAppReady) {
        needsToClearArchived = NO;
    }

    // Don't clear archived during thread import
    if ([message isKindOfClass:TSInfoMessage.class]
        && ((TSInfoMessage *)message).messageType == TSInfoMessageSyncedThread) {
        needsToClearArchived = NO;
    }

    BOOL needsToUpdateLastInteractionRowId = messageSortId > self.lastInteractionRowId;

    BOOL needsToClearIsMarkedUnread = self.isMarkedUnread && wasMessageInserted;

    if (needsToMarkAsVisible || needsToClearArchived || needsToUpdateLastInteractionRowId
        || needsToClearLastVisibleSortId || needsToClearIsMarkedUnread) {
        [self anyUpdateWithTransaction:transaction
                                 block:^(TSThread *thread) {
                                     thread.shouldThreadBeVisible = YES;
                                     thread.lastInteractionRowId = MAX(thread.lastInteractionRowId, messageSortId);
                                     if (needsToClearArchived) {
                                         thread.isArchived = NO;
                                     }
                                     if (needsToClearIsMarkedUnread) {
                                         thread.isMarkedUnread = NO;
                                     }

                                     if (needsToClearIsMarkedUnread || needsToClearArchived) {
                                         [self recordPendingStorageServiceUpdates];
                                     }
                                 }];
        if (needsToClearLastVisibleSortId) {
            [self clearLastVisibleInteractionWithTransaction:transaction];
        }
    } else {
        [self scheduleTouchFinalizationWithTransaction:transaction];
    }
}

- (void)updateWithRemovedMessage:(TSInteraction *)message transaction:(SDSAnyWriteTransaction *)transaction
{
    OWSAssertDebug(message != nil);
    OWSAssertDebug(transaction != nil);

    int64_t messageSortId = [self messageSortIdForMessage:message transaction:transaction];
    BOOL needsToUpdateLastInteractionRowId = messageSortId == self.lastInteractionRowId;

    NSNumber *_Nullable lastVisibleSortId = [self lastVisibleSortIdWithTransaction:transaction];
    BOOL needsToUpdateLastVisibleSortId
        = (lastVisibleSortId != nil && lastVisibleSortId.unsignedLongLongValue == messageSortId);

    if (needsToUpdateLastInteractionRowId || needsToUpdateLastVisibleSortId) {
        [self anyUpdateWithTransaction:transaction
                                 block:^(TSThread *thread) {
                                     if (needsToUpdateLastInteractionRowId) {
                                         TSInteraction *_Nullable latestInteraction =
                                             [thread lastInteractionForInboxWithTransaction:transaction];
                                         thread.lastInteractionRowId = latestInteraction ? latestInteraction.sortId : 0;
                                     }
                                 }];

        if (needsToUpdateLastVisibleSortId) {
            TSInteraction *_Nullable messageBeforeDeletedMessage =
                [self firstInteractionAtOrAroundSortId:lastVisibleSortId.unsignedLongLongValue transaction:transaction];
            if (messageBeforeDeletedMessage != nil) {
                [self setLastVisibleInteractionWithSortId:messageBeforeDeletedMessage.sortId
                                       onScreenPercentage:1
                                              transaction:transaction];
            } else {
                [self clearLastVisibleInteractionWithTransaction:transaction];
            }
        }
    } else {
        [self scheduleTouchFinalizationWithTransaction:transaction];
    }
}

- (void)scheduleTouchFinalizationWithTransaction:(SDSAnyWriteTransaction *)transactionForMethod
{
    OWSAssertDebug(transactionForMethod != nil);

    // If we insert, update or remove N interactions in a given
    // transactions, we don't need to touch the same thread more
    // than once.
    [transactionForMethod addTransactionFinalizationBlockForKey:self.transactionFinalizationKey
                                                          block:^(SDSAnyWriteTransaction *transactionForBlock) {
                                                              [self.databaseStorage touchThread:self
                                                                                  shouldReindex:NO
                                                                                    transaction:transactionForBlock];
                                                          }];
}

- (void)softDeleteThreadWithTransaction:(SDSAnyWriteTransaction *)transaction
{
    [self removeAllThreadInteractionsWithTransaction:transaction];
    [self anyUpdateWithTransaction:transaction
                             block:^(TSThread *thread) {
                                 thread.messageDraft = nil;
                                 thread.shouldThreadBeVisible = NO;
                             }];

    // Delete any intents we previously donated for this thread.
    [INInteraction deleteInteractionsWithGroupIdentifier:self.uniqueId completion:^(NSError *error) {}];
}

- (BOOL)hasPendingMessageRequestWithTransaction:(GRDBReadTransaction *)transaction
{
    return [GRDBThreadFinder hasPendingMessageRequestWithThread:self transaction:transaction];
}

#pragma mark - Disappearing Messages

- (OWSDisappearingMessagesConfiguration *)disappearingMessagesConfigurationWithTransaction:
    (SDSAnyReadTransaction *)transaction
{
    return [OWSDisappearingMessagesConfiguration fetchOrBuildDefaultWithThread:self transaction:transaction];
}

- (uint32_t)disappearingMessagesDurationWithTransaction:(SDSAnyReadTransaction *)transaction
{

    OWSDisappearingMessagesConfiguration *config = [self disappearingMessagesConfigurationWithTransaction:transaction];

    if (!config.isEnabled) {
        return 0;
    } else {
        return config.durationSeconds;
    }
}

#pragma mark - Archival

+ (BOOL)legacyIsArchivedWithLastMessageDate:(nullable NSDate *)lastMessageDate
                               archivalDate:(nullable NSDate *)archivalDate
{
    if (!archivalDate) {
        return NO;
    }

    if (!lastMessageDate) {
        return YES;
    }

    return [archivalDate compare:lastMessageDate] != NSOrderedAscending;
}

- (void)archiveThreadAndUpdateStorageService:(BOOL)updateStorageService
                                 transaction:(SDSAnyWriteTransaction *)transaction
{
    [self anyUpdateWithTransaction:transaction
                             block:^(TSThread *thread) {
                                 thread.isArchived = YES;
                             }];

    // We already update storage service below, so we don't need to here.
    [self markAllAsReadAndUpdateStorageService:NO transaction:transaction];

    if (updateStorageService) {
        [self recordPendingStorageServiceUpdates];
    }
}

- (void)unarchiveThreadAndUpdateStorageService:(BOOL)updateStorageService
                                   transaction:(SDSAnyWriteTransaction *)transaction
{
    [self anyUpdateWithTransaction:transaction
                             block:^(TSThread *thread) {
                                 thread.isArchived = NO;
                             }];

    if (updateStorageService) {
        [self recordPendingStorageServiceUpdates];
    }
}

- (void)unarchiveAndMarkVisibleThreadWithUpdateStorageService:(BOOL)updateStorageService
                                                  transaction:(SDSAnyWriteTransaction *)transaction
{
    [self anyUpdateWithTransaction:transaction
                             block:^(TSThread *thread) {
                                 thread.isArchived = NO;
                                 thread.shouldThreadBeVisible = YES;
                             }];

    if (updateStorageService) {
        [self recordPendingStorageServiceUpdates];
    }
}

- (void)recordPendingStorageServiceUpdates
{
    if ([self isKindOfClass:[TSGroupThread class]]) {
        TSGroupThread *groupThread = (TSGroupThread *)self;
        [SSKEnvironment.shared.storageServiceManager recordPendingUpdatesWithGroupModel:groupThread.groupModel];
    } else if ([self isKindOfClass:[TSContactThread class]]) {
        TSContactThread *contactThread = (TSContactThread *)self;
        [SSKEnvironment.shared.storageServiceManager
            recordPendingUpdatesWithUpdatedAddresses:@[ contactThread.contactAddress ]];
    } else {
        OWSFailDebug(@"unexpected thread type");
    }
}

#pragma mark - Drafts

- (nullable MessageBody *)currentDraftWithTransaction:(SDSAnyReadTransaction *)transaction
{
    TSThread *_Nullable thread = [TSThread anyFetchWithUniqueId:self.uniqueId transaction:transaction];
    if (thread.messageDraft != nil) {
        return [[MessageBody alloc] initWithText:thread.messageDraft
                                          ranges:thread.messageDraftBodyRanges ?: MessageBodyRanges.empty];
    } else {
        return nil;
    }
}

- (void)updateWithDraft:(nullable MessageBody *)draftMessageBody transaction:(SDSAnyWriteTransaction *)transaction
{
    [self anyUpdateWithTransaction:transaction
                             block:^(TSThread *thread) {
                                 thread.messageDraft = draftMessageBody.text;
                                 thread.messageDraftBodyRanges = draftMessageBody.ranges;
                             }];
}

#pragma mark - Muted

- (BOOL)isMuted
{
    NSDate *mutedUntilDate = self.mutedUntilDate;
    NSDate *now = [NSDate date];
    return (mutedUntilDate != nil &&
            [mutedUntilDate timeIntervalSinceDate:now] > 0);
}

- (void)updateWithMutedUntilDate:(nullable NSDate *)mutedUntilDate transaction:(SDSAnyWriteTransaction *)transaction
{
    [self anyUpdateWithTransaction:transaction
                             block:^(TSThread *thread) {
                                 [thread setMutedUntilDate:mutedUntilDate];
                             }];
}

- (void)updateWithMentionNotificationMode:(TSThreadMentionNotificationMode)mentionNotificationMode
                              transaction:(SDSAnyWriteTransaction *)transaction
{
    [self anyUpdateWithTransaction:transaction
                             block:^(TSThread *thread) {
                                 thread.mentionNotificationMode = mentionNotificationMode;
                             }];
}

#pragma mark - Conversation Color

- (ConversationColorName)conversationColorName
{
    OWSAssertDebug([self.class.conversationColorNames containsObject:_conversationColorName]);
    return _conversationColorName;
}

+ (NSArray<ConversationColorName> *)colorNamesForNewConversation
{
    // all conversation colors except "steel"
    return @[
        ConversationColorNameCrimson,
        ConversationColorNameVermilion,
        ConversationColorNameBurlap,
        ConversationColorNameForest,
        ConversationColorNameWintergreen,
        ConversationColorNameTeal,
        ConversationColorNameBlue,
        ConversationColorNameIndigo,
        ConversationColorNameViolet,
        ConversationColorNamePlum,
        ConversationColorNameTaupe,
    ];
}

+ (NSArray<ConversationColorName> *)conversationColorNames
{
    return [self.colorNamesForNewConversation arrayByAddingObject:ConversationColorNameDefault];
}

+ (ConversationColorName)stableConversationColorNameForString:(NSString *)colorSeed
                                                   colorNames:(NSArray<ConversationColorName> *)colorNames
{
    NSData *contactData = [colorSeed dataUsingEncoding:NSUTF8StringEncoding];

    unsigned long long hash = 0;
    NSUInteger hashingLength = sizeof(hash);
    NSData *_Nullable hashData = [Cryptography computeSHA256Digest:contactData truncatedToBytes:hashingLength];
    if (hashData) {
        [hashData getBytes:&hash length:hashingLength];
    } else {
        OWSFailDebug(@"could not compute hash for color seed.");
    }

    NSUInteger index = (hash % colorNames.count);
    return [colorNames objectAtIndex:index];
}

+ (ConversationColorName)stableColorNameForNewConversationWithString:(NSString *)colorSeed
{
    return [self stableConversationColorNameForString:colorSeed colorNames:self.colorNamesForNewConversation];
}

// After introducing new conversation colors, we want to try to maintain as close as possible to the old color for an
// existing thread.
+ (ConversationColorName)stableColorNameForLegacyConversationWithString:(NSString *)colorSeed
{
    NSString *legacyColorName =
        [self stableConversationColorNameForString:colorSeed colorNames:self.legacyConversationColorNames];
    ConversationColorName _Nullable mappedColorName = self.class.legacyConversationColorMap[legacyColorName];

    if (!mappedColorName) {
        OWSFailDebug(@"failure: unexpected unmappable legacyColorName: %@", legacyColorName);
        return ConversationColorNameDefault;
    }

    return mappedColorName;
}

+ (NSArray<NSString *> *)legacyConversationColorNames
{
    return @[
             @"red",
             @"pink",
             @"purple",
             @"indigo",
             @"blue",
             @"cyan",
             @"teal",
             @"green",
             @"deep_orange",
             @"grey"
    ];
}

+ (NSDictionary<NSString *, ConversationColorName> *)legacyConversationColorMap
{
    static NSDictionary<NSString *, ConversationColorName> *colorMap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        colorMap = @{
            @"red" : ConversationColorNameCrimson,
            @"deep_orange" : ConversationColorNameCrimson,
            @"orange" : ConversationColorNameVermilion,
            @"amber" : ConversationColorNameVermilion,
            @"brown" : ConversationColorNameBurlap,
            @"yellow" : ConversationColorNameBurlap,
            @"pink" : ConversationColorNamePlum,
            @"purple" : ConversationColorNameViolet,
            @"deep_purple" : ConversationColorNameViolet,
            @"indigo" : ConversationColorNameIndigo,
            @"blue" : ConversationColorNameBlue,
            @"light_blue" : ConversationColorNameBlue,
            @"cyan" : ConversationColorNameTeal,
            @"teal" : ConversationColorNameTeal,
            @"green" : ConversationColorNameForest,
            @"light_green" : ConversationColorNameWintergreen,
            @"lime" : ConversationColorNameWintergreen,
            @"blue_grey" : ConversationColorNameTaupe,
            @"grey" : ConversationColorNameSteel,
        };
    });

    return colorMap;
}

// we temporarily used the wrong value for the new color names.
+ (NSDictionary<NSString *, ConversationColorName> *)legacyFixupConversationColorMap
{
    static NSDictionary<NSString *, ConversationColorName> *colorMap;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        colorMap = @{
            @"crimson" : ConversationColorNameCrimson,
            @"vermilion" : ConversationColorNameVermilion,
            @"burlap" : ConversationColorNameBurlap,
            @"forest" : ConversationColorNameForest,
            @"wintergreen" : ConversationColorNameWintergreen,
            @"teal" : ConversationColorNameTeal,
            @"blue" : ConversationColorNameBlue,
            @"indigo" : ConversationColorNameIndigo,
            @"violet" : ConversationColorNameViolet,
            @"plum" : ConversationColorNamePlum,
            @"taupe" : ConversationColorNameTaupe,
            @"steel" : ConversationColorNameSteel,
        };
    });

    return colorMap;
}

- (void)updateConversationColorName:(ConversationColorName)colorName transaction:(SDSAnyWriteTransaction *)transaction
{
    [self anyUpdateWithTransaction:transaction
                             block:^(TSThread *thread) {
                                 thread.conversationColorName = colorName;
                             }];
}

@end

NS_ASSUME_NONNULL_END
