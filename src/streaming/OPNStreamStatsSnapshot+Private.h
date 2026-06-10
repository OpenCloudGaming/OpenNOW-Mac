#pragma once

#include "OPNStreamStatsSnapshot.h"
#include "OPNStreamStats.h"

@interface OPNStreamStatsSnapshot (Private)

- (instancetype)initWithStreamStats:(const OPN::StreamStats &)stats;
- (const OPN::StreamStats &)rawStats;

@end
