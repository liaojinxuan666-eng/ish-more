//
//  Roots.m
//  iSH
//
//  Created by Theodore Dubois on 6/7/20.
//

#import <FileProvider/FileProvider.h>
#import "Roots.h"
#import "AppGroup.h"
#import "NSObject+SaneKVO.h"
#include "tools/fakefs.h"

static NSURL *RootsDir(void) {
    static NSURL *rootsDir;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        NSFileManager *manager = [NSFileManager defaultManager];
        NSError *error = nil;

        // Prefer the shared container so the File Provider can access this root.
        // Never pass a nil URL to NSFileManager.
        NSURL *container = ContainerURL();
        if (container != nil) {
            NSURL *sharedRoots = [container URLByAppendingPathComponent:@"roots" isDirectory:YES];
            if ([manager createDirectoryAtURL:sharedRoots
                  withIntermediateDirectories:YES
                                   attributes:nil
                                        error:&error]) {
                rootsDir = sharedRoots;
                return;
            }
            NSLog(@"[iSH More] Cannot create App Group roots directory %@: %@", sharedRoots, error);
            error = nil;
        }

        // Keep the terminal usable if this copy was installed without a working
        // App Group entitlement. File Provider sharing will remain unavailable
        // until the app and extension are signed with the matching App Group.
        NSURL *applicationSupport = [[manager URLsForDirectory:NSApplicationSupportDirectory
                                                       inDomains:NSUserDomainMask] firstObject];
        if (applicationSupport != nil) {
            NSURL *privateRoots = [[applicationSupport URLByAppendingPathComponent:@"iSHMore" isDirectory:YES]
                                   URLByAppendingPathComponent:@"roots" isDirectory:YES];
            if ([manager createDirectoryAtURL:privateRoots
                  withIntermediateDirectories:YES
                                   attributes:nil
                                        error:&error]) {
                rootsDir = privateRoots;
                NSLog(@"[iSH More] Using private roots directory %@; File Provider sharing is disabled", privateRoots);
                return;
            }
            NSLog(@"[iSH More] Cannot create private roots directory %@: %@", privateRoots, error);
            error = nil;
        }

        // Last-resort fallback; normally Application Support is available.
        NSURL *documents = [[manager URLsForDirectory:NSDocumentDirectory
                                              inDomains:NSUserDomainMask] firstObject];
        if (documents != nil) {
            NSURL *lastResort = [[documents URLByAppendingPathComponent:@"iSHMore" isDirectory:YES]
                                 URLByAppendingPathComponent:@"roots" isDirectory:YES];
            if ([manager createDirectoryAtURL:lastResort
                  withIntermediateDirectories:YES
                                   attributes:nil
                                        error:&error]) {
                rootsDir = lastResort;
                NSLog(@"[iSH More] Using Documents fallback %@; File Provider sharing is disabled", lastResort);
                return;
            }
        }
        NSLog(@"[iSH More] FATAL: no usable roots directory: %@", error);
    });
    return rootsDir;
}

static NSString *kDefaultRoot = @"Default Root";

@interface Roots ()
@property NSMutableOrderedSet<NSString *> *roots;
@property BOOL updatingDomains;
@property BOOL domainsNeedUpdate;
@property BOOL wantsVersionFile;
@end

@implementation Roots

- (instancetype)init {
    if (self = [super init]) {
        NSError *error = nil;
        NSURL *rootsDirectory = RootsDir();
        if (rootsDirectory == nil) {
            NSLog(@"[iSH More] Failed to initialize any filesystem storage directory");
            return nil;
        }
        NSArray<NSString *> *rootNames = [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:rootsDirectory.path error:&error];
        if (rootNames == nil) {
            NSLog(@"[iSH More] Cannot list roots at %@: %@", rootsDirectory, error);
            rootNames = @[];
        }
        self.roots = [rootNames mutableCopy];
        if (!self.roots.count) {
            // import default root
            NSError *error;
            if (![self importRootFromArchive:[NSBundle.mainBundle URLForResource:@"root" withExtension:@"tar.gz"]
                                        name:@"default"
                                       error:&error
                            progressReporter:nil]) {
                NSAssert(NO, @"failed to import default root, error %@", error);
            }
            _wantsVersionFile = YES;
        }
        [self observe:@[@"roots"] options:0 owner:self usingBlock:^(typeof(self) self) {
            if (self.defaultRoot == nil && self.roots.count)
                self.defaultRoot = self.roots[0];
            [self syncFileProviderDomains];
        }];
        [self syncFileProviderDomains];

        if ((!self.defaultRoot || ![self.roots containsObject:self.defaultRoot]) && self.roots.count)
            self.defaultRoot = self.roots.firstObject;
    }
    return self;
}

- (NSString *)defaultRoot {
    return [NSUserDefaults.standardUserDefaults stringForKey:kDefaultRoot];
}
- (void)setDefaultRoot:(NSString *)defaultRoot {
    [NSUserDefaults.standardUserDefaults setObject:defaultRoot forKey:kDefaultRoot];
}

- (NSURL *)rootUrl:(NSString *)name {
    return [RootsDir() URLByAppendingPathComponent:name];
}

- (void)syncFileProviderDomains {
    if (self.updatingDomains) {
        self.domainsNeedUpdate = YES;
        return;
    }
    self.updatingDomains = YES;
    self.domainsNeedUpdate = NO;

    [NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *domains, NSError *error) {
        void (^onError)(NSError *error) = ^(NSError *error) {
            if (error != nil)
                NSLog(@"error adjusting domains: %@", error);
        };
        onError(error);
        NSMutableOrderedSet<NSString *> *missingRoots = [self.roots mutableCopy];
        for (NSFileProviderDomain *domain in domains) {
            if ([missingRoots containsObject:domain.identifier]) {
                [missingRoots removeObject:domain.identifier];
            } else {
                [NSFileManager.defaultManager removeItemAtURL:
                 [NSFileProviderManager.defaultManager.documentStorageURL
                  URLByAppendingPathComponent:domain.pathRelativeToDocumentStorage]
                                                        error:nil];
                [NSFileProviderManager removeDomain:domain completionHandler:onError];
            }
        }
        for (NSString *rootId in missingRoots) {
            [NSFileProviderManager addDomain:[[NSFileProviderDomain alloc] initWithIdentifier:rootId
                                                                                  displayName:rootId
                                                                pathRelativeToDocumentStorage:rootId]
                           completionHandler:onError];
        }
        if (self.domainsNeedUpdate)
            [self syncFileProviderDomains];
        self.updatingDomains = NO;
    }];
}

- (BOOL)accessInstanceVariablesDirectly {
    return YES;
}

void root_progress_callback(void *cookie, double progress, const char *message, bool *should_cancel) {
    id <ProgressReporter> reporter = (__bridge id<ProgressReporter>) cookie;
    [reporter updateProgress:progress message:[NSString stringWithUTF8String:message]];
    if ([reporter shouldCancel])
        *should_cancel = true;
}

- (BOOL)importRootFromArchive:(NSURL *)archive name:(NSString *)name error:(NSError **)error progressReporter:(id<ProgressReporter> _Nullable)progress {
    NSAssert(![self.roots containsObject:name], @"root already exists: %@", name);
    struct fakefsify_error fs_err;
    NSURL *destination = [self rootUrl:name];
    NSURL *tempDestination = [NSFileManager.defaultManager.temporaryDirectory
                              URLByAppendingPathComponent:[NSProcessInfo.processInfo globallyUniqueString]];
    if (tempDestination == nil)
        return NO;
    if (!fakefs_import(archive.fileSystemRepresentation,
                       tempDestination.fileSystemRepresentation,
                       &fs_err, (struct progress) {(__bridge void *) progress, root_progress_callback})) {
        NSString *domain = NSPOSIXErrorDomain;
        if (fs_err.type == ERR_SQLITE)
            domain = @"SQLite";
        *error = [NSError errorWithDomain:domain
                                     code:fs_err.code
                                 userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:@"%s, line %d", fs_err.message, fs_err.line]}];
        if (fs_err.type == ERR_CANCELLED)
            *error = nil;
        free(fs_err.message);
        [NSFileManager.defaultManager removeItemAtURL:tempDestination error:nil];
        return NO;
    }
    if (![NSFileManager.defaultManager moveItemAtURL:tempDestination toURL:destination error:error])
        return NO;

    void (^addRoot)(void) = ^{
        [[self mutableOrderedSetValueForKey:@"roots"] addObject:name];
    };
    if (!NSThread.isMainThread)
        dispatch_sync(dispatch_get_main_queue(), addRoot);
    else
        addRoot();
    return YES;
}

- (BOOL)exportRootNamed:(NSString *)name toArchive:(NSURL *)archive error:(NSError **)error progressReporter:(id<ProgressReporter> _Nullable)progress {
    NSAssert([self.roots containsObject:name], @"trying to export a root that doesn't exist: %@", name);
    struct fakefsify_error fs_err;
    if (!fakefs_export([self rootUrl:name].fileSystemRepresentation,
                       archive.fileSystemRepresentation,
                       &fs_err, (struct progress) {(__bridge void *) progress, root_progress_callback})) {
        // TODO: dedup with above method
        NSString *domain = NSPOSIXErrorDomain;
        if (fs_err.type == ERR_SQLITE)
            domain = @"SQLite";
        *error = [NSError errorWithDomain:domain
                                     code:fs_err.code
                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:fs_err.message]}];
        if (fs_err.type == ERR_CANCELLED)
            *error = nil;
        free(fs_err.message);
        return NO;
    }
    return YES;
}

- (BOOL)destroyRootNamed:(NSString *)name error:(NSError **)error {
    if ([name isEqualToString:self.defaultRoot]) {
        *error = [NSError errorWithDomain:@"iSH" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Cannot delete the default filesystem"}];
        return NO;
    }
    NSAssert([self.roots containsObject:name], @"root does not exist: %@", name);
    if (![NSFileManager.defaultManager removeItemAtURL:[self rootUrl:name] error:error])
        return NO;
    [[self mutableOrderedSetValueForKey:@"roots"] removeObject:name];
    return YES;
}

- (BOOL)renameRoot:(NSString *)name toName:(NSString *)newName error:(NSError **)error {
    if (name.length == 0) {
        *error = [NSError errorWithDomain:@"iSH" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Filesystem name can't be empty"}];
        return NO;
    }
    if ([name containsString:@"/"]) {
        *error = [NSError errorWithDomain:@"iSH" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Filesystem name can't contain /"}];
        return NO;
    }
    if ([name isEqualToString:@"."] || [name isEqualToString:@".."]) {
        *error = [NSError errorWithDomain:@"iSH" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Filesystem name can't be . or .."}];
        return NO;
    }
    if ([name isEqualToString:self.defaultRoot]) {
        *error = [NSError errorWithDomain:@"iSH" code:0 userInfo:@{NSLocalizedDescriptionKey: @"Cannot rename the default filesystem"}];
        return NO;
    }
    NSAssert([self.roots containsObject:name], @"root does not exist: %@", name);

    if (![NSFileManager.defaultManager moveItemAtURL:[self rootUrl:name] toURL:[self rootUrl:newName] error:error])
        return NO;
    NSUInteger index = [self.roots indexOfObject:name];
    [[self mutableOrderedSetValueForKey:@"roots"] replaceObjectAtIndex:index withObject:newName];
    return YES;
}

+ (instancetype)instance {
    static Roots *instance;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        instance = [Roots new];
    });
    return instance;
}

@end
