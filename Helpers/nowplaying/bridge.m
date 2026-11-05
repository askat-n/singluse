// Мост к системному «Сейчас играет». С macOS 15.4 эти данные отдаются только процессам Apple,
// поэтому библиотеку загружает системный perl (Scripts: bridge.pl), а общение идёт через stdin/stdout.
// Закрытие stdin (Singluse завершился) завершает и этот процесс.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*GetClientFn)(dispatch_queue_t, void (^)(id));
typedef void (*GetPIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef Boolean (*SendFn)(int, CFDictionaryRef);
typedef CFStringRef (*ClientStringFn)(id);

static GetInfoFn getInfo;
static GetPlayingFn getPlaying;
static GetClientFn getClient;
static GetPIDFn getPID;
static SendFn sendCommand;
static ClientStringFn clientBundle, clientParent;
static NSString *lastLine;
static NSUInteger lastArtwork;

static void emit(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void refresh(void) {
    getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef raw) {
        NSDictionary *info = (__bridge NSDictionary *)raw;
        getPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            getClient(dispatch_get_main_queue(), ^(id client) {
                getPID(dispatch_get_main_queue(), ^(int pid) {
                    NSMutableDictionary *out = [NSMutableDictionary dictionary];
                    out[@"playing"] = @(playing);
                    out[@"pid"] = @(pid);
                    if (client && clientBundle) {
                        NSString *bundle = (__bridge NSString *)clientBundle(client);
                        NSString *parent = clientParent ? (__bridge NSString *)clientParent(client) : nil;
                        if (bundle) out[@"bundle"] = bundle;
                        if (parent) out[@"parent"] = parent;
                    }
                    id title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
                    id artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
                    id album = info[@"kMRMediaRemoteNowPlayingInfoAlbum"];
                    id duration = info[@"kMRMediaRemoteNowPlayingInfoDuration"];
                    id elapsed = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
                    NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                    if (title) out[@"title"] = title;
                    if (artist) out[@"artist"] = artist;
                    if (album) out[@"album"] = album;
                    if (duration) out[@"duration"] = duration;
                    if (elapsed) out[@"elapsed"] = elapsed;
                    if ([stamp isKindOfClass:[NSDate class]]) out[@"stamp"] = @(stamp.timeIntervalSince1970);

                    NSData *data = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
                    NSString *line = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
                    NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                    NSUInteger artKey = [art isKindOfClass:[NSData class]] ? art.length : 0;
                    BOOL artChanged = artKey != lastArtwork;
                    if (artChanged) {
                        lastArtwork = artKey;
                        if (artKey) out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                        else out[@"noArtwork"] = @YES;
                    }
                    if (artChanged || ![line isEqualToString:lastLine]) {
                        lastLine = line;
                        emit(out);
                    }
                });
            });
        });
    });
}

__attribute__((visibility("default"))) void singluse_stream(void) {
    void *lib = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!lib) { puts("{\"error\":\"load\"}"); fflush(stdout); exit(2); }
    getInfo = (GetInfoFn)dlsym(lib, "MRMediaRemoteGetNowPlayingInfo");
    getPlaying = (GetPlayingFn)dlsym(lib, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getClient = (GetClientFn)dlsym(lib, "MRMediaRemoteGetNowPlayingClient");
    getPID = (GetPIDFn)dlsym(lib, "MRMediaRemoteGetNowPlayingApplicationPID");
    sendCommand = (SendFn)dlsym(lib, "MRMediaRemoteSendCommand");
    clientBundle = (ClientStringFn)dlsym(lib, "MRNowPlayingClientGetBundleIdentifier");
    clientParent = (ClientStringFn)dlsym(lib, "MRNowPlayingClientGetParentAppBundleIdentifier");
    RegisterFn registerFn = (RegisterFn)dlsym(lib, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getPlaying || !getClient || !getPID || !sendCommand || !registerFn) {
        puts("{\"error\":\"symbols\"}"); fflush(stdout); exit(3);
    }
    registerFn(dispatch_get_main_queue());
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) { refresh(); }];
    }
    // Команды приходят строками: 0 — играть, 1 — пауза, 2 — переключить, 4 — следующий, 5 — предыдущий.
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        char buffer[32];
        while (fgets(buffer, sizeof buffer, stdin)) {
            int command = atoi(buffer);
            dispatch_async(dispatch_get_main_queue(), ^{ sendCommand(command, NULL); });
        }
        exit(0);
    });
    // Подстраховка на случай пропущенного уведомления: выводится только то, что изменилось.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ refresh(); });
    dispatch_resume(timer);
    CFRunLoopRun();
}
