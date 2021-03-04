//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

#import "ExperienceUpgrade.h"

NS_ASSUME_NONNULL_BEGIN

@implementation ExperienceUpgrade

- (nullable instancetype)initWithCoder:(NSCoder *)coder
{
    return [super initWithCoder:coder];
}

- (instancetype)initWithUniqueId:(NSString *)uniqueId
{
    return [super initWithUniqueId:uniqueId];
}

// --- CODE GENERATION MARKER

// This snippet is generated by /Scripts/sds_codegen/sds_generate.py. Do not manually edit it, instead run
// `sds_codegen.sh`.

// clang-format off

- (instancetype)initWithGrdbId:(int64_t)grdbId
                      uniqueId:(NSString *)uniqueId
            firstViewedTimestamp:(double)firstViewedTimestamp
                      isComplete:(BOOL)isComplete
            lastSnoozedTimestamp:(double)lastSnoozedTimestamp
{
    self = [super initWithGrdbId:grdbId
                        uniqueId:uniqueId];

    if (!self) {
        return self;
    }

    _firstViewedTimestamp = firstViewedTimestamp;
    _isComplete = isComplete;
    _lastSnoozedTimestamp = lastSnoozedTimestamp;

    return self;
}

// clang-format on

// --- CODE GENERATION MARKER

@end

NS_ASSUME_NONNULL_END