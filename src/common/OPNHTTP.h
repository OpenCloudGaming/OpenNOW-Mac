#pragma once

#import <Foundation/Foundation.h>

namespace OPN {

NSMutableURLRequest *MakeHTTPRequest(NSString *urlString,
                                     NSString *method,
                                     NSTimeInterval timeout,
                                     NSDictionary<NSString *, NSString *> *headers);

NSData *JSONDataFromObject(id object, NSString **errorMessage);
id JSONObjectFromData(NSData *data, NSString **errorMessage);

bool ValidateHTTPResponse(NSURLResponse *response,
                          NSData *data,
                          NSError *error,
                          NSInteger expectedStatus,
                          NSString **errorMessage);

}
