// HNMediaBridge – runs inside /usr/bin/perl (see hn-media.pl).
//
// Since macOS 15.4 the private MediaRemote framework only answers processes
// that Apple signed. /usr/bin/perl is one of them and can load this library,
// so the app starts perl as a helper and talks to it over stdin/stdout:
//
//   stdout  one JSON object per line ({"type":"state", ...})
//   stdin   one command per line: "cmd <n>", "seek <seconds>",
//           "shuffle <mode>", "repeat <mode>", "refresh"
//
// The helper exits as soon as stdin closes, so it never outlives the app.

#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*MRRegisterFn)(dispatch_queue_t);
typedef void (*MRGetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPIDFn)(dispatch_queue_t, void (^)(int));
typedef Boolean (*MRSendCommandFn)(int, NSDictionary *);
typedef void (*MRSetElapsedFn)(double);
typedef void (*MRSetModeFn)(int);

static MRGetInfoFn getInfo;
static MRGetPlayingFn getPlaying;
static MRGetPIDFn getPID;
static MRSendCommandFn sendCommand;
static MRSetElapsedFn setElapsed;
static MRSetModeFn setShuffle;
static MRSetModeFn setRepeat;

static NSUInteger lastArtworkHash = 0;
static BOOL refreshScheduled = NO;

static void emit(NSDictionary *payload) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!json) return;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static id numberOrNull(id value) {
    return [value isKindOfClass:[NSNumber class]] ? value : [NSNull null];
}

static id stringOrNull(id value) {
    return [value isKindOfClass:[NSString class]] ? value : [NSNull null];
}

static void fetchAndEmit(void) {
    getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        getPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            getPID(dispatch_get_main_queue(), ^(int pid) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"type"] = @"state";
                out[@"playing"] = @(playing);
                out[@"pid"] = @(pid);
                if (info.count == 0) {
                    out[@"empty"] = @YES;
                    lastArtworkHash = 0;
                    emit(out);
                    return;
                }
                out[@"title"] = stringOrNull(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
                out[@"artist"] = stringOrNull(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
                out[@"album"] = stringOrNull(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
                out[@"duration"] = numberOrNull(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
                out[@"elapsed"] = numberOrNull(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
                out[@"rate"] = numberOrNull(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
                out[@"shuffle"] = numberOrNull(info[@"kMRMediaRemoteNowPlayingInfoShuffleMode"]);
                out[@"repeat"] = numberOrNull(info[@"kMRMediaRemoteNowPlayingInfoRepeatMode"]);
                NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                out[@"timestamp"] = [stamp isKindOfClass:[NSDate class]] ? @(stamp.timeIntervalSince1970) : [NSNull null];

                NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([artwork isKindOfClass:[NSData class]] && artwork.length > 0) {
                    NSUInteger hash = artwork.hash ^ artwork.length;
                    out[@"artworkId"] = @(hash);
                    if (hash != lastArtworkHash) {
                        out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
                        lastArtworkHash = hash;
                    }
                } else {
                    out[@"artworkId"] = @0;
                    lastArtworkHash = 0;
                }
                emit(out);
            });
        });
    });
}

// Several notifications usually arrive together; coalesce them.
static void scheduleRefresh(void) {
    if (refreshScheduled) return;
    refreshScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        refreshScheduled = NO;
        fetchAndEmit();
    });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *verb = parts.firstObject;
    double arg = parts.count > 1 ? parts[1].doubleValue : 0;
    if ([verb isEqualToString:@"cmd"]) {
        sendCommand((int)arg, nil);
    } else if ([verb isEqualToString:@"seek"]) {
        setElapsed(arg);
    } else if ([verb isEqualToString:@"shuffle"]) {
        setShuffle((int)arg);
    } else if ([verb isEqualToString:@"repeat"]) {
        setRepeat((int)arg);
    }
    scheduleRefresh();
}

static void readCommands(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char buffer[512];
        while (fgets(buffer, sizeof buffer, stdin)) {
            NSString *line = [[NSString stringWithUTF8String:buffer]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (line.length == 0) continue;
            dispatch_async(dispatch_get_main_queue(), ^{ handleCommand(line); });
        }
        exit(0);
    });
}

void hn_run(void) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!mr) {
        emit(@{@"type": @"error", @"message": @"MediaRemote not found"});
        exit(2);
    }
    MRRegisterFn registerFn = (MRRegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    getInfo = (MRGetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getPlaying = (MRGetPlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPID = (MRGetPIDFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    sendCommand = (MRSendCommandFn)dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = (MRSetElapsedFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    setShuffle = (MRSetModeFn)dlsym(mr, "MRMediaRemoteSetShuffleMode");
    setRepeat = (MRSetModeFn)dlsym(mr, "MRMediaRemoteSetRepeatMode");
    if (!registerFn || !getInfo || !getPlaying || !getPID || !sendCommand || !setElapsed || !setShuffle || !setRepeat) {
        emit(@{@"type": @"error", @"message": @"MediaRemote symbols missing"});
        exit(3);
    }

    registerFn(dispatch_get_main_queue());
    NSArray *names = @[
        @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
    ];
    for (NSString *name in names) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) { scheduleRefresh(); }];
    }

    emit(@{@"type": @"ready"});
    readCommands();
    fetchAndEmit();
    CFRunLoopRun();
}
