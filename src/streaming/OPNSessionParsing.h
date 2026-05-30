#pragma once

#import <Foundation/Foundation.h>

namespace OPN {

NSArray *ArrayValue(id value);
NSDictionary *DictionaryValue(id value);
NSString *StringValue(id value);
int PositiveIntValue(id value);
bool BoolValue(id value, bool fallback = false);

}
