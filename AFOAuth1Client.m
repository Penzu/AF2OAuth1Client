// AFOAuth1Client.m
//
// Copyright (c) 2011 Mattt Thompson (http://mattt.me/)
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFOAuth1Client.h"
#import "AFHTTPRequestOperation.h"

#import <CommonCrypto/CommonHMAC.h>

static NSString * AFEncodeBase64WithData(NSData *data) {
    NSUInteger length = [data length];
    NSMutableData *mutableData = [NSMutableData dataWithLength:((length + 2) / 3) * 4];
    
    uint8_t *input = (uint8_t *)[data bytes];
    uint8_t *output = (uint8_t *)[mutableData mutableBytes];
    
    for (NSUInteger i = 0; i < length; i += 3) {
        NSUInteger value = 0;
        for (NSUInteger j = i; j < (i + 3); j++) {
            value <<= 8;
            if (j < length) {
                value |= (0xFF & input[j]);
            }
        }
        
        static uint8_t const kAFBase64EncodingTable[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        
        NSUInteger idx = (i / 3) * 4;
        output[idx + 0] = kAFBase64EncodingTable[(value >> 18) & 0x3F];
        output[idx + 1] = kAFBase64EncodingTable[(value >> 12) & 0x3F];
        output[idx + 2] = (i + 1) < length ? kAFBase64EncodingTable[(value >> 6)  & 0x3F] : '=';
        output[idx + 3] = (i + 2) < length ? kAFBase64EncodingTable[(value >> 0)  & 0x3F] : '=';
    }
    
    return [[NSString alloc] initWithData:mutableData encoding:NSASCIIStringEncoding];
}

static NSString * AFPercentEscapedQueryStringPairMemberFromStringWithEncoding(NSString *string, NSStringEncoding encoding) {
    static NSString * const kAFCharactersToBeEscaped = @":/?&=;+!@#$()~";
    static NSString * const kAFCharactersToLeaveUnescaped = @"[].";
    
	return (__bridge_transfer  NSString *)CFURLCreateStringByAddingPercentEscapes(kCFAllocatorDefault, (__bridge CFStringRef)string, (__bridge CFStringRef)kAFCharactersToLeaveUnescaped, (__bridge CFStringRef)kAFCharactersToBeEscaped, CFStringConvertNSStringEncodingToEncoding(encoding));
}

static NSDictionary * AFParametersFromQueryString(NSString *queryString) {
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    if (queryString) {
        NSScanner *parameterScanner = [[NSScanner alloc] initWithString:queryString];
        NSString *name = nil;
        NSString *value = nil;
        
        while (![parameterScanner isAtEnd]) {
            name = nil;        
            [parameterScanner scanUpToString:@"=" intoString:&name];
            [parameterScanner scanString:@"=" intoString:NULL];
            
            value = nil;
            [parameterScanner scanUpToString:@"&" intoString:&value];
            [parameterScanner scanString:@"&" intoString:NULL];		
            
            if (name && value) {
                [parameters setValue:[value stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] forKey:[name stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
            }
        }
    }
    
    return parameters;
}

static inline BOOL AFQueryStringValueIsTrue(NSString *value) {
    return value && [[value lowercaseString] hasPrefix:@"t"];
}

@interface AFOAuth1Token ()
@property (readwrite, nonatomic, copy) NSString *key;
@property (readwrite, nonatomic, copy) NSString *secret;
@property (readwrite, nonatomic, copy) NSString *session;
@property (readwrite, nonatomic, copy) NSString *verifier;
@property (readwrite, nonatomic, strong) NSDate *expiration;
@property (readwrite, nonatomic, assign, getter = canBeRenewed) BOOL renewable;
@end

@implementation AFOAuth1Token
@synthesize key = _key;
@synthesize secret = _secret;
@synthesize session = _session;
@synthesize verifier = _verifier;
@synthesize expiration = _expiration;
@synthesize renewable = _renewable;
@dynamic expired;

- (id)initWithQueryString:(NSString *)queryString {
    self = [super init];
    if (!self) {
        return nil;
    }
    
    NSDictionary *attributes = AFParametersFromQueryString(queryString);
    
    self.key = attributes[@"oauth_token"];
    self.secret = attributes[@"oauth_token_secret"];
    self.session = attributes[@"oauth_session_handle"];
    
    if (attributes[@"oauth_token_duration"]) {
        self.expiration = [NSDate dateWithTimeIntervalSinceNow:[attributes[@"oauth_token_duration"] doubleValue]];
    }
    
    if (attributes[@"oauth_token_renewable"]) {
        self.renewable = AFQueryStringValueIsTrue(attributes[@"oauth_token_renewable"]);
    }
    
    return self;
}

@end

#pragma mark -

NSString * const kAFOAuth1Version = @"1.0";
NSString * const kAFApplicationLaunchedWithURLNotification = @"kAFApplicationLaunchedWithURLNotification";
#if __IPHONE_OS_VERSION_MIN_REQUIRED
NSString * const kAFApplicationLaunchOptionsURLKey = @"UIApplicationLaunchOptionsURLKey";
#else
NSString * const kAFApplicationLaunchOptionsURLKey = @"NSApplicationLaunchOptionsURLKey";
#endif

static inline NSString * AFNounce() {
    CFUUIDRef uuid = CFUUIDCreate(NULL);
    CFStringRef string = CFUUIDCreateString(NULL, uuid);
    CFRelease(uuid);
    
    return (NSString *)CFBridgingRelease(string);
}

static inline NSString * NSStringFromAFOAuthSignatureMethod(AFOAuthSignatureMethod signatureMethod) {
    switch (signatureMethod) {
        case AFHMACSHA1SignatureMethod:
            return @"HMAC-SHA1";
        case AFPlaintextSignatureMethod:
            return @"PLAINTEXT";
        default:
            return nil;
    }
}

static inline NSString * AFHMACSHA1Signature(NSURLRequest *request, NSString *consumerSecret, NSString *requestTokenSecret, NSStringEncoding stringEncoding) {
    NSString* reqSecret = @"";
    if (requestTokenSecret != nil) {
        reqSecret = requestTokenSecret;
    }
    NSString *secretString = [NSString stringWithFormat:@"%@&%@", consumerSecret, reqSecret];
    NSData *secretStringData = [secretString dataUsingEncoding:stringEncoding];
    
    NSString *queryString = AFPercentEscapedQueryStringPairMemberFromStringWithEncoding([[[[[request URL] query] componentsSeparatedByString:@"&"] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)] componentsJoinedByString:@"&"], stringEncoding);
    
    NSString *requestString = [NSString stringWithFormat:@"%@&%@&%@", [request HTTPMethod], AFPercentEscapedQueryStringPairMemberFromStringWithEncoding([[[request URL] absoluteString] componentsSeparatedByString:@"?"][0], stringEncoding), queryString];
    NSData *requestStringData = [requestString dataUsingEncoding:stringEncoding];
    
    // hmac
    uint8_t digest[CC_SHA1_DIGEST_LENGTH];
    CCHmacContext cx;
    CCHmacInit(&cx, kCCHmacAlgSHA1, [secretStringData bytes], [secretStringData length]);
    CCHmacUpdate(&cx, [requestStringData bytes], [requestStringData length]);
    CCHmacFinal(&cx, digest);
    
    // base 64
    NSData *data = [NSData dataWithBytes:digest length:CC_SHA1_DIGEST_LENGTH];
    return AFEncodeBase64WithData(data);
}

static inline NSString * AFPlaintextSignature(NSString *consumerSecret, NSString *requestTokenSecret, NSStringEncoding stringEncoding) {
    // TODO
    return nil;
}

@interface AFOAuth1Client ()
@property (readwrite, nonatomic, copy) NSString *key;
@property (readwrite, nonatomic, copy) NSString *secret;

- (void) signCallPerAuthHeaderWithPath:(NSString *)path 
                         andParameters:(NSDictionary *)parameters 
                             andMethod:(NSString *)method ;
- (NSDictionary *) signCallWithHttpGetWithPath:(NSString *)path 
                                 andParameters:(NSDictionary *)parameters 
                                     andMethod:(NSString *)method ;
@end

@implementation AFOAuth1Client
@synthesize key = _key;
@synthesize secret = _secret;
@synthesize signatureMethod = _signatureMethod;
@synthesize realm = _realm;
@synthesize oauthAccessMethod = _oauthAccessMethod;

- (id)initWithBaseURL:(NSURL *)url
                  key:(NSString *)clientID
               secret:(NSString *)secret
{
    NSParameterAssert(clientID);
    NSParameterAssert(secret);

    self = [super initWithBaseURL:url];
    if (!self) {
        return nil;
    }
    
    self.key = clientID;
    self.secret = secret;
            
    self.oauthAccessMethod = @"GET";
    
    return self;
}

- (void)authorizeUsingOAuthWithRequestTokenPath:(NSString *)requestTokenPath
                          userAuthorizationPath:(NSString *)userAuthorizationPath
                                    callbackURL:(NSURL *)callbackURL
                                accessTokenPath:(NSString *)accessTokenPath
                                   accessMethod:(NSString *)accessMethod
                                        success:(void (^)(AFOAuth1Token *accessToken))success 
                                        failure:(void (^)(NSError *error))failure
{
    [self acquireOAuthRequestTokenWithPath:requestTokenPath callback:callbackURL accessMethod:(NSString *)accessMethod success:^(AFOAuth1Token *requestToken) {
        __block AFOAuth1Token *currentRequestToken = requestToken;
        [[NSNotificationCenter defaultCenter] addObserverForName:kAFApplicationLaunchedWithURLNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *notification) {
            
            NSURL *url = [[notification userInfo] valueForKey:kAFApplicationLaunchOptionsURLKey];
            
            currentRequestToken.verifier = [AFParametersFromQueryString([url query]) valueForKey:@"oauth_verifier"];
                        
            [self acquireOAuthAccessTokenWithPath:accessTokenPath requestToken:currentRequestToken accessMethod:accessMethod success:^(AFOAuth1Token * accessToken) {
                if (success) {
                    success(accessToken);
                }
            } failure:^(NSError *error) {
                if (failure) {
                    failure(error);
                }
            }];
        }];
                
        NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
        [parameters setValue:requestToken.key forKey:@"oauth_token"];
#if __IPHONE_OS_VERSION_MIN_REQUIRED
        [[UIApplication sharedApplication] openURL:[[self requestWithMethod:@"GET" path:userAuthorizationPath parameters:parameters] URL]];
#else
        [[NSWorkspace sharedWorkspace] openURL:[[self requestWithMethod:@"GET" path:userAuthorizationPath parameters:parameters] URL]];
#endif
    } failure:^(NSError *error) {
        if (failure) {
            failure(error);
        }
    }];
}

- (NSDictionary *)OAuthParameters {
    NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
    [parameters setValue:kAFOAuth1Version forKey:@"oauth_version"];
    [parameters setValue:NSStringFromAFOAuthSignatureMethod(self.signatureMethod) forKey:@"oauth_signature_method"];
    [parameters setValue:self.key forKey:@"oauth_consumer_key"];
    [parameters setValue:[[NSNumber numberWithInteger:floorf([[NSDate date] timeIntervalSince1970])] stringValue] forKey:@"oauth_timestamp"];
    [parameters setValue:AFNounce() forKey:@"oauth_nonce"];

    if (self.realm) {
        [parameters setValue:self.realm forKey:@"realm"];
    }

    return parameters;
}

- (NSString *)OAuthSignatureForMethod:(NSString *)method
                                 path:(NSString *)path
                           parameters:(NSDictionary *)parameters
                         requestToken:(AFOAuth1Token *)requestToken
{
    NSMutableURLRequest *request = [self requestWithMethod:@"HEAD" path:path parameters:parameters];
    [request setHTTPMethod:method];

    switch (self.signatureMethod) {
        case AFHMACSHA1SignatureMethod:
            return AFHMACSHA1Signature(request, self.secret, requestToken ? requestToken.secret : nil, self.stringEncoding);
        case AFPlaintextSignatureMethod:
//            return AFPlaintextSignature(consumerSecret, requestTokenSecret, stringEncoding);
        default:
            return nil;
    }
}

- (void)acquireOAuthRequestTokenWithPath:(NSString *)path
                                callback:(NSURL *)callbackURL
                            accessMethod:(NSString *)accessMethod
                                 success:(void (^)(AFOAuth1Token *requestToken))success 
                                 failure:(void (^)(NSError *error))failure
{    
    NSMutableDictionary *parameters = [[self OAuthParameters] mutableCopy];
    [parameters setValue:[callbackURL absoluteString] forKey:@"oauth_callback"];
    
    [parameters setValue:[self OAuthSignatureForMethod:accessMethod path:path parameters:parameters requestToken:nil] forKey:@"oauth_signature"];

    NSMutableURLRequest *request = [self requestWithMethod:accessMethod path:path parameters:parameters];
    [request setHTTPBody:nil];
    [request setValue:[self authorizationHeaderForParameters:parameters] forHTTPHeaderField:@"Authorization"];

    AFHTTPRequestOperation *operation = [self HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
        if (success) {
            AFOAuth1Token *accessToken = [[AFOAuth1Token alloc] initWithQueryString:operation.responseString];
            success(accessToken);
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        if (failure) {
            failure(error);
        }
    }];

    [self enqueueHTTPRequestOperation:operation];
}

- (void)acquireOAuthAccessTokenWithPath:(NSString *)path
                           requestToken:(AFOAuth1Token *)requestToken
                           accessMethod:(NSString *)accessMethod
                                success:(void (^)(AFOAuth1Token *accessToken))success 
                                failure:(void (^)(NSError *error))failure
{    
    NSMutableDictionary *parameters = [[self OAuthParameters] mutableCopy];
    [parameters setValue:requestToken.key forKey:@"oauth_token"];
    [parameters setValue:requestToken.verifier forKey:@"oauth_verifier"];

    [parameters setValue:[self OAuthSignatureForMethod:accessMethod path:path parameters:parameters requestToken:requestToken] forKey:@"oauth_signature"];

    NSMutableURLRequest *request = [self requestWithMethod:accessMethod path:path parameters:parameters];
    [request setValue:[self authorizationHeaderForParameters:parameters] forHTTPHeaderField:@"Authorization"];

    AFHTTPRequestOperation *operation = [self HTTPRequestOperationWithRequest:request success:^(AFHTTPRequestOperation *operation, id responseObject) {
        if (success) {
            AFOAuth1Token *accessToken = [[AFOAuth1Token alloc] initWithQueryString:operation.responseString];
            success(accessToken);
        }
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        if (failure) {
            failure(error);
        }
    }];

    [self enqueueHTTPRequestOperation:operation];
}

- (NSString *)authorizationHeaderForParameters:(NSDictionary *)parameters {
    NSArray *sortedComponents = [[AFQueryStringFromParametersWithEncoding(parameters, self.stringEncoding) componentsSeparatedByString:@"&"] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    NSMutableArray *mutableComponents = [NSMutableArray array];
    for (NSString *component in sortedComponents) {
        NSArray *subcomponents = [component componentsSeparatedByString:@"="];
        [mutableComponents addObject:[NSString stringWithFormat:@"%@=\"%@\"", [subcomponents objectAtIndex:0], [subcomponents objectAtIndex:1]]];
    }

    return [NSString stringWithFormat:@"OAuth %@", [mutableComponents componentsJoinedByString:@", "]];
}

#pragma mark - AFHTTPClient

- (NSMutableURLRequest *)requestWithMethod:(NSString *)method
                                      path:(NSString *)path
                                parameters:(NSDictionary *)parameters
{
    NSMutableURLRequest *request = [super requestWithMethod:method path:path parameters:parameters];
    [request setHTTPShouldHandleCookies:NO];

    return request;
}

//- (AFHTTPRequestOperation *)HTTPRequestOperationWithRequest:(NSURLRequest *)urlRequest
//                                                    success:(void (^)(AFHTTPRequestOperation *, id))success
//                                                    failure:(void (^)(AFHTTPRequestOperation *, NSError *))failure
//{
//    if (self.accessToken) {
//        if ([self.oauthAccessMethod isEqualToString:@"GET"])
//            parameters = [self signCallWithHttpGetWithPath:path andParameters:parameters andMethod:@"GET"];
//        else
//            [self signCallPerAuthHeaderWithPath:path andParameters:parameters andMethod:@"GET"];
//    }
//
//    AFHTTPRequestOperation *operation = [super HTTPRequestOperationWithRequest:urlRequest success:success failure:failure];
//}

//- (void) signCallPerAuthHeaderWithPath:(NSString *)path usingParameters:(NSMutableDictionary *)parameters andMethod:(NSString *)method {
//    NSMutableURLRequest *request = [self requestWithMethod:@"GET" path:path parameters:parameters];
//    [request setHTTPMethod:method];
////    [parameters setValue:AFSignatureUsingMethodWithSignatureWithConsumerSecretAndRequestTokenSecret(request, self.signatureMethod, self.secret, self.accessToken.secret, self.stringEncoding) forKey:@"oauth_signature"];
//
//    
//    NSArray *sortedComponents = [[AFQueryStringFromParametersWithEncoding(parameters, self.stringEncoding) componentsSeparatedByString:@"&"] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
//    NSMutableArray *mutableComponents = [NSMutableArray array];
//    for (NSString *component in sortedComponents) {
//        NSArray *subcomponents = [component componentsSeparatedByString:@"="];
//        [mutableComponents addObject:[NSString stringWithFormat:@"%@=\"%@\"", subcomponents[0], subcomponents[1]]];
//    }
//    
//    NSString *oauthString = [NSString stringWithFormat:@"OAuth %@", [mutableComponents componentsJoinedByString:@", "]];
//    
//    NSLog(@"OAuth: %@", oauthString);
//    
//    [self setDefaultHeader:@"Authorization" value:oauthString];
//}
//

@end
