// MediaRemote adapter hosted inside the Apple-signed /usr/bin/perl.
//
// Recent macOS releases only answer MediaRemote now-playing reads for
// Apple-entitled processes, so NooL App loads this library into perl via core
// DynaLoader and talks to it over pipes:
//   stdout: one JSON object per line ("ready", "nowPlaying", "idle", "command")
//   stdin:  one command per line ("refresh", "toggle", "play", "pause",
//           "next", "previous", "seek <seconds>")
// The adapter exits when stdin closes, so it never outlives NooL App. It never
// writes payloads anywhere except stdout.

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

#include "NoolMediaRemoteAdapter.h"

#if !__has_feature(objc_arc)
#error "NoolMediaRemoteAdapter relies on ARC for the values captured by MediaRemote blocks"
#endif

typedef void (*MRRegisterFunction)(dispatch_queue_t);
typedef void (*MRGetInfoFunction)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetIsPlayingFunction)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFunction)(dispatch_queue_t, void (^)(int));
typedef void (*MRGetClientFunction)(dispatch_queue_t, void (^)(id));
typedef CFStringRef (*MRClientStringFunction)(id);
typedef Boolean (*MRSendCommandFunction)(uint32_t, CFDictionaryRef);
typedef void (*MRSetElapsedTimeFunction)(double);

enum {
    NoolMRCommandPlay = 0,
    NoolMRCommandPause = 1,
    NoolMRCommandTogglePlayPause = 2,
    NoolMRCommandNextTrack = 4,
    NoolMRCommandPreviousTrack = 5,
};

static const NSUInteger NoolMaximumArtworkBytes = 4 * 1024 * 1024;
static const NSUInteger NoolMaximumCommandLineBytes = 256;

static MRRegisterFunction registerForNotifications;
static MRGetInfoFunction getNowPlayingInfo;
static MRGetIsPlayingFunction getIsPlaying;
static MRGetPIDFunction getApplicationPID;
static MRGetClientFunction getNowPlayingClient;
static MRClientStringFunction clientBundleIdentifier;
static MRClientStringFunction clientParentBundleIdentifier;
static MRClientStringFunction clientDisplayName;
static MRSendCommandFunction sendCommand;
static MRSetElapsedTimeFunction setElapsedTime;

static NSString *lastEmittedLine;
static NSString *lastArtworkIdentifier;
static BOOL refreshScheduled;
static NSMutableData *inputBuffer;
static dispatch_source_t inputSource;

static void writeLine(NSString *line) {
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *bytes = data.bytes;
    size_t remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(STDOUT_FILENO, bytes, remaining);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            // NooL App closed the pipe; nobody is listening any more.
            _exit(0);
        }
        bytes += written;
        remaining -= (size_t)written;
    }
}

static void emitObject(NSDictionary *object) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    if (json == nil) {
        return;
    }
    NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    if (line == nil) {
        return;
    }
    writeLine(line);
}

static id valueForKeys(NSDictionary *info, NSArray<NSString *> *keys, Class expectedClass) {
    for (NSString *key in keys) {
        id value = info[key];
        if ([value isKindOfClass:expectedClass]) {
            return value;
        }
    }
    return nil;
}

static NSString *stringForKeys(NSDictionary *info, NSArray<NSString *> *keys) {
    NSString *value = valueForKeys(info, keys, [NSString class]);
    return value.length > 0 ? value : nil;
}

static NSString *clientString(MRClientStringFunction function, id client) {
    if (function == NULL || client == nil) {
        return nil;
    }
    NSString *value = (__bridge NSString *)function(client);
    return [value isKindOfClass:[NSString class]] && value.length > 0 ? value : nil;
}

static NSString *artworkIdentifier(NSData *artwork) {
    // Cheap change detector; equal artwork must not be re-sent on every tick.
    const uint8_t *bytes = artwork.bytes;
    uint64_t hash = 1469598103934665603ULL;
    for (NSUInteger index = 0; index < artwork.length; index++) {
        hash ^= bytes[index];
        hash *= 1099511628211ULL;
    }
    return [NSString stringWithFormat:@"%lu-%016llx", (unsigned long)artwork.length, hash];
}

static void emitSnapshot(NSDictionary *info, BOOL isPlaying, int pid, id client) {
    NSString *title = stringForKeys(info, @[@"kMRMediaRemoteNowPlayingInfoTitle"]);
    if (title == nil) {
        lastArtworkIdentifier = nil;
        NSString *line = @"{\"type\":\"idle\"}";
        if (![line isEqualToString:lastEmittedLine]) {
            lastEmittedLine = line;
            writeLine(line);
        }
        return;
    }

    NSMutableDictionary *object = [NSMutableDictionary dictionary];
    object[@"type"] = @"nowPlaying";
    object[@"title"] = title;
    object[@"playing"] = @(isPlaying);

    NSString *artist = stringForKeys(info, @[@"kMRMediaRemoteNowPlayingInfoArtist"]);
    NSString *album = stringForKeys(info, @[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
    NSString *identifier = stringForKeys(info, @[
        @"kMRMediaRemoteNowPlayingInfoUniqueIdentifier",
        @"kMRMediaRemoteNowPlayingInfoContentItemIdentifier"
    ]);
    if (artist) object[@"artist"] = artist;
    if (album) object[@"album"] = album;
    if (identifier) object[@"id"] = identifier;

    NSNumber *duration = valueForKeys(info, @[@"kMRMediaRemoteNowPlayingInfoDuration"], [NSNumber class]);
    NSNumber *elapsed = valueForKeys(info, @[@"kMRMediaRemoteNowPlayingInfoElapsedTime"], [NSNumber class]);
    NSNumber *rate = valueForKeys(info, @[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"], [NSNumber class]);
    NSDate *timestamp = valueForKeys(info, @[@"kMRMediaRemoteNowPlayingInfoTimestamp"], [NSDate class]);
    if (duration) object[@"duration"] = duration;
    if (elapsed) object[@"elapsed"] = elapsed;
    if (rate) object[@"rate"] = rate;
    if (timestamp) object[@"timestamp"] = @(timestamp.timeIntervalSince1970);

    NSString *bundleIdentifier = clientString(clientParentBundleIdentifier, client)
        ?: clientString(clientBundleIdentifier, client);
    NSString *appName = clientString(clientDisplayName, client);
    if (pid > 0) {
        NSRunningApplication *application = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (bundleIdentifier == nil) bundleIdentifier = application.bundleIdentifier;
        if (appName == nil) appName = application.localizedName;
    }
    if (bundleIdentifier != nil && appName == nil) {
        NSRunningApplication *application =
            [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier].firstObject;
        appName = application.localizedName;
    }
    if (bundleIdentifier) object[@"bundleIdentifier"] = bundleIdentifier;
    if (appName) object[@"appName"] = appName;

    NSData *artwork = valueForKeys(info, @[@"kMRMediaRemoteNowPlayingInfoArtworkData"], [NSData class]);
    if (artwork.length > 0 && artwork.length <= NoolMaximumArtworkBytes) {
        NSString *artworkID = artworkIdentifier(artwork);
        object[@"artworkId"] = artworkID;
        NSString *mimeType = stringForKeys(info, @[@"kMRMediaRemoteNowPlayingInfoArtworkMIMEType"]);
        if (mimeType) object[@"artworkMimeType"] = mimeType;

        // Compare without the artwork bytes so an unchanged frame is skipped.
        NSData *json = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:NULL];
        NSString *line = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
        if (line != nil && [line isEqualToString:lastEmittedLine]) {
            return;
        }
        lastEmittedLine = line;
        if (![artworkID isEqualToString:lastArtworkIdentifier]) {
            object[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
            lastArtworkIdentifier = artworkID;
        }
        emitObject(object);
        return;
    }

    lastArtworkIdentifier = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:NULL];
    NSString *line = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
    if (line == nil || [line isEqualToString:lastEmittedLine]) {
        return;
    }
    lastEmittedLine = line;
    writeLine(line);
}

static void refreshNow(BOOL force) {
    if (force) {
        lastEmittedLine = nil;
        lastArtworkIdentifier = nil;
    }
    dispatch_queue_t queue = dispatch_get_main_queue();
    dispatch_group_t group = dispatch_group_create();
    __block NSDictionary *info = nil;
    __block BOOL isPlaying = NO;
    __block int pid = 0;
    __block id client = nil;

    dispatch_group_enter(group);
    getNowPlayingInfo(queue, ^(CFDictionaryRef value) {
        info = [(__bridge NSDictionary *)value copy];
        dispatch_group_leave(group);
    });
    if (getIsPlaying != NULL) {
        dispatch_group_enter(group);
        getIsPlaying(queue, ^(Boolean value) {
            isPlaying = value;
            dispatch_group_leave(group);
        });
    }
    if (getApplicationPID != NULL) {
        dispatch_group_enter(group);
        getApplicationPID(queue, ^(int value) {
            pid = value;
            dispatch_group_leave(group);
        });
    }
    if (getNowPlayingClient != NULL) {
        dispatch_group_enter(group);
        getNowPlayingClient(queue, ^(id value) {
            client = value;
            dispatch_group_leave(group);
        });
    }

    dispatch_group_notify(group, queue, ^{
        if (getIsPlaying == NULL) {
            NSNumber *rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
            isPlaying = [rate isKindOfClass:[NSNumber class]] && rate.doubleValue > 0;
        }
        emitSnapshot(info, isPlaying, pid, client);
    });
}

static void scheduleRefresh(void) {
    // Notifications arrive in bursts; coalesce them into one read.
    if (refreshScheduled) {
        return;
    }
    refreshScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        refreshScheduled = NO;
        refreshNow(NO);
    });
}

static void reportCommand(NSString *name, BOOL ok) {
    emitObject(@{@"type": @"command", @"name": name, @"ok": @(ok)});
    scheduleRefresh();
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *name = parts.firstObject;
    if ([name isEqualToString:@"refresh"]) {
        // Unchanged state is not re-sent; NooL keeps the last snapshot.
        refreshNow(NO);
        return;
    }
    if ([name isEqualToString:@"seek"]) {
        double position = parts.count > 1 ? parts[1].doubleValue : -1;
        if (setElapsedTime == NULL || !isfinite(position) || position < 0) {
            reportCommand(name, NO);
            return;
        }
        setElapsedTime(position);
        reportCommand(name, YES);
        return;
    }

    uint32_t command;
    if ([name isEqualToString:@"toggle"]) {
        command = NoolMRCommandTogglePlayPause;
    } else if ([name isEqualToString:@"play"]) {
        command = NoolMRCommandPlay;
    } else if ([name isEqualToString:@"pause"]) {
        command = NoolMRCommandPause;
    } else if ([name isEqualToString:@"next"]) {
        command = NoolMRCommandNextTrack;
    } else if ([name isEqualToString:@"previous"]) {
        command = NoolMRCommandPreviousTrack;
    } else {
        return;
    }
    BOOL ok = sendCommand != NULL && sendCommand(command, NULL);
    reportCommand(name, ok);
}

static void readInput(void) {
    uint8_t buffer[1024];
    ssize_t count = read(STDIN_FILENO, buffer, sizeof buffer);
    if (count == 0 || (count < 0 && errno != EINTR && errno != EAGAIN)) {
        // NooL App went away or closed the pipe: the adapter must not linger.
        exit(0);
    }
    if (count < 0) {
        return;
    }
    [inputBuffer appendBytes:buffer length:(NSUInteger)count];
    while (YES) {
        const uint8_t *bytes = inputBuffer.bytes;
        const uint8_t *newline = memchr(bytes, '\n', inputBuffer.length);
        if (newline == NULL) {
            if (inputBuffer.length > NoolMaximumCommandLineBytes) {
                inputBuffer.length = 0;
            }
            return;
        }
        NSUInteger length = (NSUInteger)(newline - bytes);
        NSString *line = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
        [inputBuffer replaceBytesInRange:NSMakeRange(0, length + 1) withBytes:NULL length:0];
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length > 0) {
            handleCommand(line);
        }
    }
}

static void *loadSymbol(void *handle, const char *name) {
    return handle == NULL ? NULL : dlsym(handle, name);
}

void nool_media_remote_adapter_main(void *interpreter, void *cv) {
    (void)interpreter;
    (void)cv;
    signal(SIGPIPE, SIG_IGN);

    @autoreleasepool {
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        registerForNotifications = (MRRegisterFunction)loadSymbol(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
        getNowPlayingInfo = (MRGetInfoFunction)loadSymbol(handle, "MRMediaRemoteGetNowPlayingInfo");
        getIsPlaying = (MRGetIsPlayingFunction)loadSymbol(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        getApplicationPID = (MRGetPIDFunction)loadSymbol(handle, "MRMediaRemoteGetNowPlayingApplicationPID");
        getNowPlayingClient = (MRGetClientFunction)loadSymbol(handle, "MRMediaRemoteGetNowPlayingClient");
        clientBundleIdentifier = (MRClientStringFunction)loadSymbol(handle, "MRNowPlayingClientGetBundleIdentifier");
        clientParentBundleIdentifier = (MRClientStringFunction)loadSymbol(handle, "MRNowPlayingClientGetParentAppBundleIdentifier");
        clientDisplayName = (MRClientStringFunction)loadSymbol(handle, "MRNowPlayingClientGetDisplayName");
        sendCommand = (MRSendCommandFunction)loadSymbol(handle, "MRMediaRemoteSendCommand");
        setElapsedTime = (MRSetElapsedTimeFunction)loadSymbol(handle, "MRMediaRemoteSetElapsedTime");

        if (getNowPlayingInfo == NULL || registerForNotifications == NULL) {
            emitObject(@{@"type": @"unavailable"});
            exit(3);
        }

        registerForNotifications(dispatch_get_main_queue());
        NSArray<NSString *> *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
            @"kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification"
        ];
        for (NSString *name in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name
                                                              object:nil
                                                               queue:nil
                                                          usingBlock:^(__unused NSNotification *note) {
                // MediaRemote posts synchronously from its own queue and would
                // block on an operation-queue hop; never wait for the main thread.
                dispatch_async(dispatch_get_main_queue(), ^{
                    scheduleRefresh();
                });
            }];
        }

        inputBuffer = [NSMutableData data];
        inputSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(inputSource, ^{
            readInput();
        });
        dispatch_resume(inputSource);

        emitObject(@{@"type": @"ready", @"version": @1});
        refreshNow(YES);
    }

    // MediaRemote needs a live main run loop; the distant timer keeps
    // CFRunLoopRun from returning while the loop has no other sources.
    CFRunLoopTimerRef keepAlive = CFRunLoopTimerCreateWithHandler(
        kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 1e9, 1e9, 0, 0,
        ^(__unused CFRunLoopTimerRef timer) {});
    CFRunLoopAddTimer(CFRunLoopGetMain(), keepAlive, kCFRunLoopCommonModes);
    while (true) {
        CFRunLoopRun();
    }
}
