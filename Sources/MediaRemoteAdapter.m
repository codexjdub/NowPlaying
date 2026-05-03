// Minimal MediaRemote adapter for use as a dylib loaded by /usr/bin/perl.
// Apple-signed perl has the entitlements MediaRemote requires; calls made
// from a dylib loaded into perl inherit that calling-process context, so
// MRMediaRemoteGetNowPlayingInfo returns real data even on macOS 15.4+.
//
// Single export: adapter_get
// Behavior: prints a single JSON object to stdout with keys
//   { "title": ..., "artist": ..., "album": ..., "playing": bool }
// All keys are optional; an empty object means nothing is playing.

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#include <stdio.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*SetCanBeFn)(Boolean);
typedef void (*GetIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));

// Note: MRMediaRemoteSendCommand is restricted on macOS 15.4+ even when
// called via the perl + dylib trick — the system silently drops the command.
// We use synthetic media keys (NSEvent.systemDefined) on the Swift side
// instead. See main.swift.

static void writeJSON(NSDictionary *obj) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (data) {
        fwrite([data bytes], 1, [data length], stdout);
    } else {
        fputs("{}", stdout);
    }
    fputc('\n', stdout);
    fflush(stdout);
}

__attribute__((visibility("default")))
void adapter_get(void) {
    @autoreleasepool {
        CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:
            @"/System/Library/PrivateFrameworks/MediaRemote.framework"];
        CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, url);
        if (!bundle) { writeJSON(@{}); return; }

        RegisterFn reg = (RegisterFn)CFBundleGetFunctionPointerForName(
            bundle, CFSTR("MRMediaRemoteRegisterForNowPlayingNotifications"));
        SetCanBeFn setCanBe = (SetCanBeFn)CFBundleGetFunctionPointerForName(
            bundle, CFSTR("MRMediaRemoteSetCanBeNowPlayingApplication"));
        GetInfoFn getInfo = (GetInfoFn)CFBundleGetFunctionPointerForName(
            bundle, CFSTR("MRMediaRemoteGetNowPlayingInfo"));
        GetIsPlayingFn getIsPlaying = (GetIsPlayingFn)CFBundleGetFunctionPointerForName(
            bundle, CFSTR("MRMediaRemoteGetNowPlayingApplicationIsPlaying"));

        dispatch_queue_t q = dispatch_queue_create("nowplaying.adapter", DISPATCH_QUEUE_SERIAL);
        if (reg) reg(q);
        if (setCanBe) setCanBe(false);

        if (!getInfo) { writeJSON(@{}); return; }

        dispatch_group_t group = dispatch_group_create();
        __block NSDictionary *info = nil;
        __block BOOL playing = NO;

        dispatch_group_enter(group);
        getInfo(q, ^(NSDictionary *result) {
            info = result;
            dispatch_group_leave(group);
        });

        if (getIsPlaying) {
            dispatch_group_enter(group);
            getIsPlaying(q, ^(Boolean isPlaying) {
                playing = isPlaying ? YES : NO;
                dispatch_group_leave(group);
            });
        }

        dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC);
        dispatch_group_wait(group, timeout);

        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        if (info) {
            NSString *title  = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
            NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"];
            NSString *album  = info[@"kMRMediaRemoteNowPlayingInfoAlbum"];
            if (title)  out[@"title"]  = title;
            if (artist) out[@"artist"] = artist;
            if (album)  out[@"album"]  = album;
        }
        out[@"playing"] = @(playing);

        writeJSON(out);
    }
}
