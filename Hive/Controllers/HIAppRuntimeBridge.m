//
//  HIAppRuntimeBridge.m
//  Hive
//
//  Created by Bazyli Zygan on 27.06.2013.
//  Copyright (c) 2013 Hive Developers. All rights reserved.
//

#import <AFNetworking/AFNetworking.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import "BCClient.h"
#import "HIAppRuntimeBridge.h"
#import "HICurrencyAmountFormatter.h"
#import "HIProfile.h"

#define SafeJSONValue(x) ((x) ?: [NSNull null])
#define IsNullOrUndefined(x) (!(x) || [(x) isKindOfClass:[WebUndefined class]])

@interface HIAppRuntimeBridge ()
{
    NSDateFormatter *_ISODateFormatter;
    HICurrencyAmountFormatter *_currencyFormatter;
    NSInteger _BTCInSatoshi;
    NSInteger _mBTCInSatoshi;
    NSInteger _uBTCInSatoshi;
    NSString *_IncomingTransactionType;
    NSString *_OutgoingTransactionType;
    NSString *_hiveVersionNumber;
    NSString *_hiveBuildNumber;
    NSString *_locale;
}

@end


@implementation HIAppRuntimeBridge

- (id)init
{
    self = [super init];

    if (self)
    {
        _ISODateFormatter = [[NSDateFormatter alloc] init];
        _ISODateFormatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
        _currencyFormatter = [[HICurrencyAmountFormatter alloc] init];

        _BTCInSatoshi = SATOSHI;
        _mBTCInSatoshi = SATOSHI / 1000;
        _uBTCInSatoshi = SATOSHI / 1000 / 1000;

        _IncomingTransactionType = @"incoming";
        _OutgoingTransactionType = @"outgoing";

        _hiveBuildNumber = [[NSBundle mainBundle] infoDictionary][@"CFBundleVersion"];
        _hiveVersionNumber = [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"];

        NSArray *languages = [[NSUserDefaults standardUserDefaults] arrayForKey:@"AppleLanguages"];
        NSArray *preferredLanguages =
            (__bridge NSArray *)CFBundleCopyPreferredLocalizationsFromArray((__bridge CFArrayRef)languages);
        _locale = preferredLanguages[0];
    }

    return self;
}

- (void)killCallbacks
{
}

- (void)sendMoneyToAddress:(NSString *)hash amount:(NSNumber *)amount callback:(WebScriptObject *)callback
{
    if (IsNullOrUndefined(hash))
    {
        [WebScriptObject throwException:@"hash argument is undefined"];
        return;
    }

    NSDecimalNumber *decimal = nil;

    if (!IsNullOrUndefined(amount))
    {
        decimal = [NSDecimalNumber decimalNumberWithMantissa:[amount integerValue]
                                                    exponent:-8
                                                  isNegative:NO];
    }

    [self.controller requestPaymentToHash:hash
                                   amount:decimal
                               completion:^(BOOL success, NSString *transactionId) {
        if (!IsNullOrUndefined(callback))
        {
            JSObjectRef ref = [callback JSObject];

            if (!ref)
            {
                // app was already closed
                return;
            }

            JSContextRef ctx = self.frame.globalContext;

            if (success)
            {
                JSStringRef idParam = JSStringCreateWithCFString((__bridge CFStringRef) transactionId);

                JSValueRef params[2];
                params[0] = JSValueMakeBoolean(ctx, YES);
                params[1] = JSValueMakeString(ctx, idParam);

                JSObjectCallAsFunction(ctx, ref, NULL, 2, params, NULL);
                JSStringRelease(idParam);
            }
            else
            {
                JSValueRef result = JSValueMakeBoolean(ctx, NO);
                JSObjectCallAsFunction(ctx, ref, NULL, 1, &result, NULL);
            }
        }
    }];
}

- (void)transactionWithHash:(NSString *)hash callback:(WebScriptObject *)callback
{
    if (IsNullOrUndefined(callback))
    {
        [WebScriptObject throwException:@"callback argument is undefined"];
        return;
    }

    JSObjectRef ref = [callback JSObject];
    JSContextRef ctx = self.frame.globalContext;

    NSDictionary *data = [[BCClient sharedClient] transactionDefinitionWithHash:hash];

    if (!data)
    {
        JSValueRef nullValue = JSValueMakeNull(ctx);
        JSObjectCallAsFunction(ctx, ref, NULL, 1, &nullValue, NULL);
        return;
    }

    NSInteger amount = [data[@"amount"] integerValue];
    NSInteger absolute = labs(amount);
    BOOL incoming = (amount >= 0);

    NSArray *inputs = [data[@"details"] filteredArrayUsingPredicate:
                       [NSPredicate predicateWithFormat:@"category = 'received'"]];
    NSArray *outputs = [data[@"details"] filteredArrayUsingPredicate:
                        [NSPredicate predicateWithFormat:@"category = 'sent'"]];

    NSDictionary *transaction = @{
                                  @"id": data[@"txid"],
                                  @"type": (incoming ? _IncomingTransactionType : _OutgoingTransactionType),
                                  @"amount": @(absolute),
                                  @"timestamp": [_ISODateFormatter stringFromDate:data[@"time"]],
                                  @"inputAddresses": [inputs valueForKey:@"address"],
                                  @"outputAddresses": [outputs valueForKey:@"address"]
                                };

    JSValueRef jsonValue = [self valueObjectFromDictionary:transaction];
    JSObjectCallAsFunction(ctx, ref, NULL, 1, &jsonValue, NULL);
}

- (void)getUserInformationWithCallback:(WebScriptObject *)callback
{
    if (IsNullOrUndefined(callback))
    {
        [WebScriptObject throwException:@"callback argument is undefined"];
        return;
    }

    JSObjectRef ref = [callback JSObject];
    JSContextRef ctx = self.frame.globalContext;

    HIProfile *profile = [[HIProfile alloc] init];

    NSDictionary *data = @{
                           @"firstName": SafeJSONValue(profile.firstname),
                           @"lastName": SafeJSONValue(profile.lastname),
                           @"email": SafeJSONValue(profile.email),
                           @"address": [[BCClient sharedClient] walletHash]
                         };

    JSValueRef jsonValue = [self valueObjectFromDictionary:data];
    JSObjectCallAsFunction(ctx, ref, NULL, 1, &jsonValue, NULL);
}

- (void)getSystemInfoWithCallback:(WebScriptObject *)callback
{
    if (IsNullOrUndefined(callback))
    {
        [WebScriptObject throwException:@"callback argument is undefined"];
        return;
    }

    JSObjectRef ref = [callback JSObject];
    JSContextRef ctx = self.frame.globalContext;

    NSDictionary *data = @{
                           @"decimalSeparator": _currencyFormatter.decimalSeparator
                         };

    JSValueRef jsonValue = [self valueObjectFromDictionary:data];
    JSObjectCallAsFunction(ctx, ref, NULL, 1, &jsonValue, NULL);
}

- (void)makeProxiedRequestToURL:(NSString *)url options:(WebScriptObject *)options
{
    if (IsNullOrUndefined(url))
    {
        [WebScriptObject throwException:@"url argument is undefined"];
        return;
    }

    JSContextRef context = self.frame.globalContext;

    NSString *HTTPMethod = [self webScriptObject:options valueForProperty:@"type"] ?: @"GET";
    WebScriptObject *successCallback = [self webScriptObject:options valueForProperty:@"success"];
    WebScriptObject *errorCallback = [self webScriptObject:options valueForProperty:@"error"];
    WebScriptObject *completeCallback = [self webScriptObject:options valueForProperty:@"complete"];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    [request setHTTPMethod:HTTPMethod];

    AFHTTPRequestOperation *operation = [[AFHTTPRequestOperation alloc] initWithRequest:request];

    [operation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject) {
        NSString *text = [[NSString alloc] initWithData:responseObject encoding:operation.responseStringEncoding];

        NSLog(@"success: %@", text);

        if (successCallback)
        {
            JSObjectCallAsFunction(context, [successCallback JSObject], NULL, 0, NULL, NULL);
        }

        if (completeCallback)
        {
            JSObjectCallAsFunction(context, [completeCallback JSObject], NULL, 0, NULL, NULL);
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        NSLog(@"error: %@", error);

        if (errorCallback)
        {
            JSObjectCallAsFunction(context, [errorCallback JSObject], NULL, 0, NULL, NULL);
        }

        if (completeCallback)
        {
            JSObjectCallAsFunction(context, [completeCallback JSObject], NULL, 0, NULL, NULL);
        }
    }];

    [operation start];
}

- (JSValueRef)valueObjectFromDictionary:(NSDictionary *)dictionary
{
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:NULL];
    NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];

    JSStringRef jsString = JSStringCreateWithCFString((__bridge CFStringRef) jsonString);
    JSValueRef jsValue = JSValueMakeFromJSONString(self.frame.globalContext, jsString);
    JSStringRelease(jsString);

    return jsValue;
}

- (id)webScriptObject:(WebScriptObject *)object valueForProperty:(NSString *)property
{
    if ([self webScriptObject:object hasProperty:property])
    {
        return [object valueForKey:property];
    }
    else
    {
        return nil;
    }
}

- (BOOL)webScriptObject:(WebScriptObject *)object hasProperty:(NSString *)property
{
    if (IsNullOrUndefined(object))
    {
        return NO;
    }

    JSStringRef jsString = JSStringCreateWithCFString((__bridge CFStringRef) property);
    BOOL hasProperty = JSObjectHasProperty(self.frame.globalContext, [object JSObject], jsString);
    JSStringRelease(jsString);

    return hasProperty;
}

+ (NSDictionary *)selectorMap
{
    static NSDictionary *selectorMap;

    if (!selectorMap)
    {
        selectorMap = @{
                        @"sendMoneyToAddress:amount:callback:": @"sendMoney",
                        @"transactionWithHash:callback:": @"getTransaction",
                        @"getUserInformationWithCallback:": @"getUserInfo",
                        @"getSystemInfoWithCallback:": @"getSystemInfo",
                        @"makeProxiedRequestToURL:options:": @"makeRequest",
                      };
    }

    return selectorMap;
}

+ (NSDictionary *)keyMap
{
    static NSDictionary *keyMap;

    if (!keyMap)
    {
        keyMap = @{
                   @"_BTCInSatoshi": @"BTC_IN_SATOSHI",
                   @"_mBTCInSatoshi": @"MBTC_IN_SATOSHI",
                   @"_uBTCInSatoshi": @"UBTC_IN_SATOSHI",
                   @"_IncomingTransactionType": @"TX_TYPE_INCOMING",
                   @"_OutgoingTransactionType": @"TX_TYPE_OUTGOING",
                   @"_hiveBuildNumber": @"BUILD_NUMBER",
                   @"_hiveVersionNumber": @"VERSION",
                   @"_locale": @"LOCALE",
                 };
    }

    return keyMap;
}

+ (NSString *)webScriptNameForSelector:(SEL)sel
{
    return [self selectorMap][NSStringFromSelector(sel)];
}

+ (BOOL)isSelectorExcludedFromWebScript:(SEL)sel
{
    return ([self selectorMap][NSStringFromSelector(sel)] == nil);
}

+ (NSString *)webScriptNameForKey:(const char *)name
{
    NSString *key = [NSString stringWithCString:name encoding:NSASCIIStringEncoding];
    return [self keyMap][key];
}

+ (BOOL)isKeyExcludedFromWebScript:(const char *)name
{
    NSString *key = [NSString stringWithCString:name encoding:NSASCIIStringEncoding];
    return ([self keyMap][key] == nil);
}

@end
