#include "OPNHTTP.h"

namespace OPN {

static void OPNSetErrorMessage(NSString **errorMessage, NSString *message) {
    if (errorMessage) *errorMessage = message ?: @"Unknown error";
}

NSMutableURLRequest *MakeHTTPRequest(NSString *urlString,
                                     NSString *method,
                                     NSTimeInterval timeout,
                                     NSDictionary<NSString *, NSString *> *headers) {
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    if (!url) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method.length > 0 ? method : @"GET";
    request.timeoutInterval = timeout;
    for (NSString *key in headers) {
        NSString *value = headers[key];
        if (key.length > 0 && value.length > 0) [request setValue:value forHTTPHeaderField:key];
    }
    return request;
}

NSData *JSONDataFromObject(id object, NSString **errorMessage) {
    if (!object) {
        OPNSetErrorMessage(errorMessage, @"Missing JSON object");
        return nil;
    }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (!data) {
        OPNSetErrorMessage(errorMessage, [NSString stringWithFormat:@"Invalid JSON object: %@", error.localizedDescription ?: @"unknown error"]);
    }
    return data;
}

id JSONObjectFromData(NSData *data, NSString **errorMessage) {
    if (data.length == 0) {
        OPNSetErrorMessage(errorMessage, @"Empty response body");
        return nil;
    }
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (!object) {
        OPNSetErrorMessage(errorMessage, [NSString stringWithFormat:@"Invalid JSON: %@", error.localizedDescription ?: @"unknown error"]);
    }
    return object;
}

bool ValidateHTTPResponse(NSURLResponse *response,
                          NSData *data,
                          NSError *error,
                          NSInteger expectedStatus,
                          NSString **errorMessage) {
    if (error) {
        OPNSetErrorMessage(errorMessage, error.localizedDescription ?: @"Network error");
        return false;
    }
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    if (!http) {
        OPNSetErrorMessage(errorMessage, @"Missing HTTP response");
        return false;
    }
    if (http.statusCode != expectedStatus) {
        OPNSetErrorMessage(errorMessage, [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]);
        return false;
    }
    if (!data) {
        OPNSetErrorMessage(errorMessage, @"Empty response body");
        return false;
    }
    return true;
}

}
