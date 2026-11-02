#import <Foundation/Foundation.h>
#include <math.h>
#include <stdio.h>
#include <unistd.h>

// Exercise the real private emission functions without starting MediaRemote.
#import "../../Sources/NoolMediaRemoteAdapter/NoolMediaRemoteAdapter.m"

@interface ThrowingJSONDictionary : NSDictionary
@end

@implementation ThrowingJSONDictionary
- (NSUInteger)count { return 1; }
- (NSEnumerator *)keyEnumerator { return [@[@"synthetic"] objectEnumerator]; }
- (id)objectForKey:(id)key {
    (void)key;
    @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Synthetic malformed JSON object" userInfo:nil];
}
- (void)enumerateKeysAndObjectsUsingBlock:(void (NS_NOESCAPE ^)(id, id, BOOL *))block {
    (void)block;
    @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Synthetic malformed JSON object" userInfo:nil];
}
@end

static void require(BOOL condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static NSData *capture(void (^operation)(void)) {
    int descriptors[2];
    require(pipe(descriptors) == 0, "create output pipe");
    int saved = dup(STDOUT_FILENO);
    require(saved >= 0 && dup2(descriptors[1], STDOUT_FILENO) >= 0, "redirect output");
    close(descriptors[1]);
    @try {
        operation();
    } @finally {
        require(dup2(saved, STDOUT_FILENO) >= 0, "restore output");
        close(saved);
    }
    NSMutableData *output = [NSMutableData data];
    uint8_t buffer[4096];
    ssize_t count;
    while ((count = read(descriptors[0], buffer, sizeof buffer)) > 0) {
        [output appendBytes:buffer length:(NSUInteger)count];
    }
    close(descriptors[0]);
    return output;
}

static NSDictionary *oneObject(NSData *output) {
    require(output.length > 0, "snapshot emitted JSON");
    NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
    require([[text componentsSeparatedByString:@"\n"] count] == 2, "exactly one JSON line");
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:output options:0 error:&error];
    require(error == nil && [object isKindOfClass:[NSDictionary class]], "output is valid JSON object");
    return object;
}

static NSMutableDictionary *metadata(BOOL artwork) {
    NSMutableDictionary *info = [@{
        @"kMRMediaRemoteNowPlayingInfoTitle": @"Synthetic title",
        @"kMRMediaRemoteNowPlayingInfoArtist": @"Synthetic artist",
        @"kMRMediaRemoteNowPlayingInfoAlbum": @"Synthetic album",
        @"kMRMediaRemoteNowPlayingInfoUniqueIdentifier": @"synthetic-id",
        @"kMRMediaRemoteNowPlayingInfoDuration": @240.5,
        @"kMRMediaRemoteNowPlayingInfoElapsedTime": @12.25,
        @"kMRMediaRemoteNowPlayingInfoPlaybackRate": @1.0,
        @"kMRMediaRemoteNowPlayingInfoTimestamp": [NSDate dateWithTimeIntervalSince1970:1700000000.5]
    } mutableCopy];
    if (artwork) {
        info[@"kMRMediaRemoteNowPlayingInfoArtworkData"] = [@"synthetic artwork" dataUsingEncoding:NSUTF8StringEncoding];
        info[@"kMRMediaRemoteNowPlayingInfoArtworkMIMEType"] = @"image/png";
    }
    return info;
}

static NSDictionary *snapshot(NSDictionary *info) {
    lastEmittedLine = nil;
    lastArtworkIdentifier = nil;
    return oneObject(capture(^{ emitSnapshot(info, YES, 0, nil); }));
}

static void checkMetadata(NSDictionary *object, BOOL artwork) {
    require([object[@"type"] isEqual:@"nowPlaying"], "snapshot type preserved");
    require([object[@"title"] isEqual:@"Synthetic title"], "title preserved");
    require([object[@"artist"] isEqual:@"Synthetic artist"], "artist preserved");
    require([object[@"album"] isEqual:@"Synthetic album"], "album preserved");
    require([object[@"id"] isEqual:@"synthetic-id"], "identifier preserved");
    require([object[@"playing"] isEqual:@YES], "playing state preserved");
    if (artwork) {
        require([object[@"artwork"] isEqual:[[metadata(YES) objectForKey:@"kMRMediaRemoteNowPlayingInfoArtworkData"] base64EncodedStringWithOptions:0]], "artwork preserved");
        require([object[@"artworkId"] isKindOfClass:[NSString class]], "artwork identifier preserved");
        require([object[@"artworkMimeType"] isEqual:@"image/png"], "artwork MIME preserved");
    } else {
        require(object[@"artwork"] == nil && object[@"artworkId"] == nil, "no unexpected artwork");
    }
}

static void testNormalSnapshots(void) {
    for (NSNumber *withArtwork in @[@NO, @YES]) {
        NSDictionary *object = snapshot(metadata(withArtwork.boolValue));
        checkMetadata(object, withArtwork.boolValue);
        require([object[@"duration"] isEqual:@240.5], "finite duration preserved");
        require([object[@"elapsed"] isEqual:@12.25], "finite elapsed preserved");
        require([object[@"rate"] isEqual:@1.0], "finite rate preserved");
        require([object[@"timestamp"] isEqual:@1700000000.5], "finite timestamp preserved");
    }
}

static void testNonfiniteTiming(void) {
    NSArray<NSString *> *inputKeys = @[@"kMRMediaRemoteNowPlayingInfoDuration", @"kMRMediaRemoteNowPlayingInfoElapsedTime", @"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
    NSArray<NSString *> *outputKeys = @[@"duration", @"elapsed", @"rate"];
    for (NSNumber *withArtwork in @[@NO, @YES]) {
        for (NSNumber *invalid in @[@(NAN), @(INFINITY), @(-INFINITY), [NSDecimalNumber notANumber]]) {
            for (NSUInteger index = 0; index < inputKeys.count; index++) {
                NSMutableDictionary *info = metadata(withArtwork.boolValue);
                info[inputKeys[index]] = invalid;
                NSDictionary *object = snapshot(info);
                checkMetadata(object, withArtwork.boolValue);
                require(object[outputKeys[index]] == nil, "invalid optional timing omitted");
                for (NSUInteger other = 0; other < inputKeys.count; other++) {
                    if (other != index) {
                        require([object[outputKeys[other]] isEqual:info[inputKeys[other]]], "unaffected timing preserved");
                    }
                }
            }
        }
        for (NSNumber *invalid in @[@(NAN), @(INFINITY), @(-INFINITY)]) {
            NSMutableDictionary *info = metadata(withArtwork.boolValue);
            info[@"kMRMediaRemoteNowPlayingInfoTimestamp"] = [NSDate dateWithTimeIntervalSince1970:invalid.doubleValue];
            NSDictionary *object = snapshot(info);
            checkMetadata(object, withArtwork.boolValue);
            require(object[@"timestamp"] == nil, "nonfinite timestamp omitted");
            require([object[@"duration"] isEqual:@240.5], "duration survives invalid timestamp");
        }
        NSMutableDictionary *info = metadata(withArtwork.boolValue);
        for (NSString *key in inputKeys) { info[key] = @(NAN); }
        info[@"kMRMediaRemoteNowPlayingInfoTimestamp"] = @"invalid timestamp type";
        NSDictionary *object = snapshot(info);
        checkMetadata(object, withArtwork.boolValue);
        require(object[@"duration"] == nil && object[@"elapsed"] == nil && object[@"rate"] == nil && object[@"timestamp"] == nil,
                "invalid timing together omitted without losing metadata");
    }
}

static void testGenericEmissionBoundary(void) {
    for (NSNumber *invalid in @[@(NAN), @(INFINITY), @(-INFINITY)]) {
        require(capture(^{ emitObject(@{@"type": @"synthetic", @"invalid": invalid}); }).length == 0,
                "generic emission rejects nonfinite numeric payload");
        require(capture(^{ emitObject(@{@"type": @"synthetic", @"nested": @[@{@"invalid": invalid}]}); }).length == 0,
                "generic emission rejects nested nonfinite numeric payload");
    }
    require(capture(^{ emitObject(@{@"unsupported": [NSDate date]}); }).length == 0,
            "generic emission rejects unsupported object");
    require(capture(^{ emitObject([ThrowingJSONDictionary new]); }).length == 0,
            "generic emission contains malformed object exceptions");
    NSDictionary *normal = oneObject(capture(^{ emitObject(@{@"type": @"command", @"name": @"synthetic", @"ok": @YES, @"value": @42.5}); }));
    require([normal[@"value"] isEqual:@42.5] && [normal[@"ok"] isEqual:@YES], "generic valid emission survives rejected payloads");
}

static void testArtworkDeduplication(void) {
    NSMutableDictionary *info = metadata(YES);
    NSDictionary *first = snapshot(info);
    info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] = @(NAN);
    NSDictionary *second = oneObject(capture(^{ emitSnapshot(info, YES, 0, nil); }));
    require([first[@"artworkId"] isEqual:second[@"artworkId"]] && second[@"artwork"] == nil,
            "unchanged artwork is not resent after invalid timing");
    require(second[@"elapsed"] == nil && [second[@"duration"] isEqual:@240.5], "updated timing stays valid with cached artwork");
    require(capture(^{ emitSnapshot(info, YES, 0, nil); }).length == 0, "unchanged sanitized snapshot is deduplicated");
}

static void proveUnsafeSerialization(void) {
    BOOL raised = NO;
    @try {
        [NSJSONSerialization dataWithJSONObject:@{@"duration": @(NAN)} options:0 error:NULL];
    } @catch (__unused NSException *exception) {
        raised = YES;
    }
    require(raised, "unguarded Foundation serialization reproduces exception");
    fprintf(stderr, "PASS: original nonfinite serialization exception reproduced and caught\n");
}

int main(void) {
    @autoreleasepool {
        @try {
            proveUnsafeSerialization();
            testNormalSnapshots();
            testNonfiniteTiming();
            testGenericEmissionBoundary();
            testArtworkDeduplication();
            fprintf(stderr, "PASS: MediaRemote native JSON regression checks\n");
        } @catch (NSException *exception) {
            fprintf(stderr, "FAIL: unexpected exception (%s)\n", exception.name.UTF8String);
            return 1;
        }
    }
    return 0;
}
