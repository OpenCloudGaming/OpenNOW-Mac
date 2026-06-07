#include "OPNHTTP.h"
#include "OPNSentry.h"

namespace OPN {

static void OPNSetErrorMessage(NSString **errorMessage, NSString *message) {
    if (errorMessage) *errorMessage = message ?: @"Unknown error";
}

static NSString *OPNHTTPStatusBucket(NSInteger statusCode) {
    if (statusCode < 100) return @"unknown";
    return [NSString stringWithFormat:@"%ldxx", (long)(statusCode / 100)];
}

static NSDictionary<NSString *, id> *OPNHTTPMetricAttributes(NSURLResponse *response,
                                                             NSError *error,
                                                             NSInteger expectedStatus,
                                                             NSString *outcome) {
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    NSMutableDictionary<NSString *, id> *attributes = [@{
        @"outcome": outcome.length > 0 ? outcome : @"unknown",
        @"method": @"unknown",
        @"host": http.URL.host.length > 0 ? http.URL.host : @"unknown",
        @"expected_status": @(expectedStatus),
    } mutableCopy];
    if (http) {
        attributes[@"status_code"] = @(http.statusCode);
        attributes[@"status_bucket"] = OPNHTTPStatusBucket(http.statusCode);
    }
    if (error.domain.length > 0) {
        attributes[@"error_domain"] = error.domain;
        attributes[@"error_code"] = @(error.code);
    }
    return attributes;
}

static void OPNRecordHTTPMetric(NSURLResponse *response, NSError *error, NSInteger expectedStatus, NSString *outcome) {
    OPN::RecordSentryCounterMetric("opennow.http.requests.count", 1, OPNHTTPMetricAttributes(response, error, expectedStatus, outcome));
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
    OPN::AddSentryTraceHeaders(request);
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
        OPNRecordHTTPMetric(response, error, expectedStatus, @"network_error");
        return false;
    }
    NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
    if (!http) {
        OPNSetErrorMessage(errorMessage, @"Missing HTTP response");
        OPNRecordHTTPMetric(response, nil, expectedStatus, @"missing_response");
        return false;
    }
    if (http.statusCode != expectedStatus) {
        OPNSetErrorMessage(errorMessage, [NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]);
        OPNRecordHTTPMetric(response, nil, expectedStatus, @"http_error");
        return false;
    }
    if (!data) {
        OPNSetErrorMessage(errorMessage, @"Empty response body");
        OPNRecordHTTPMetric(response, nil, expectedStatus, @"empty_body");
        return false;
    }
    OPNRecordHTTPMetric(response, nil, expectedStatus, @"success");
    return true;
}

}
