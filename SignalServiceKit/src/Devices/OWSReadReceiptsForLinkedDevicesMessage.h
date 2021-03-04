//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

#import "OWSOutgoingSyncMessage.h"

NS_ASSUME_NONNULL_BEGIN

@class OWSLinkedDeviceReadReceipt;

@interface OWSReadReceiptsForLinkedDevicesMessage : OWSOutgoingSyncMessage

+ (instancetype)new NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithThread:(TSThread *)thread NS_UNAVAILABLE;
- (instancetype)initWithTimestamp:(uint64_t)timestamp thread:(TSThread *)thread NS_UNAVAILABLE;

- (instancetype)initWithThread:(TSThread *)thread
                  readReceipts:(NSArray<OWSLinkedDeviceReadReceipt *> *)readReceipts NS_DESIGNATED_INITIALIZER;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END
