//
//  Roots.m
//  iSH
//
//  Root storage and Files.app visibility support for iSH More.
//

#import <FileProvider/FileProvider.h>
#import "Roots.h"
#import "AppGroup.h"
#import "NSObject+SaneKVO.h"
#include "tools/fakefs.h"

// The normal "On My iPhone > iSH More" folder is the app's Documents
// directory. User themes already live there; expose the active Linux root as
// Documents/Linux so it is visible there even when an App Group entitlement
// is not available to the sideloaded app.
static NSURL *DocumentsLinuxURL(void) {
    NSURL *documents = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                              inDomains:NSUserDomainMask].firstObject;
    if (documents == nil)
        return nil;
    return [documents URLByAppendingPathComponent:@"Linux" isDirectory:YES];
}

static BOOL PathsEqual(NSString *a, NSString *b) {
    if (a == nil || b == nil)
        return NO;
    return [[a stringByStandardizingPath] isEqualToString:[b stringByStandardizingPath]];
}

static NSURL *RootsDir(void) {
    static NSURL *rootsDir;
    static dispatch_once_t token;
    dispatch_once(&token, ^{
        NSFileManager *manager = [NSFileManager defaultManager];
        NSError *error = nil;

        // Keep root metadata in the shared container when available.
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

        // Unsigned/ad-hoc builds may not have a usable App Group entitlement.
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
                NSLog(@"[iSH More] Root metadata directory: %@", privateRoots);
                return;
            }
            NSLog(@"[iSH More] Cannot create private roots directory %@: %@", privateRoots, error);
            error = nil;
        }

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
                NSLog(@"[iSH More] Using Documents fallback for root metadata: %@", lastResort);
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
- (BOOL)exposeDataForRootName:(NSString *)name;
- (BOOL)restoreDataForRootName:(NSString *)name;
@end

@implementation Roots

- (BOOL)restoreDataForRootName:(NSString *)name {
    if (name.length == 0)
        return YES;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *rootDirectory = [RootsDir() URLByAppendingPathComponent:name isDirectory:YES];
    NSURL *dataURL = [rootDirectory URLByAppendingPathComponent:@"data" isDirectory:YES];
    NSURL *visibleURL = DocumentsLinuxURL();
    if (visibleURL == nil)
        return NO;

    NSString *linkTarget = [manager destinationOfSymbolicLinkAtPath:dataURL.path error:nil];
    if (!PathsEqual(linkTarget, visibleURL.path))
        return YES; // This root is not currently exposed through Documents.

    BOOL isDirectory = NO;
    if (![manager fileExistsAtPath:visibleURL.path isDirectory:&isDirectory] || !isDirectory) {
        NSLog(@"[iSH More] Cannot switch root %@: Documents/Linux is missing", name);
        return NO;
    }

    NSError *error = nil;
    if (![manager removeItemAtURL:dataURL error:&error]) {
        NSLog(@"[iSH More] Cannot remove data link for root %@: %@", name, error);
        return NO;
    }
    if (![manager moveItemAtURL:visibleURL toURL:dataURL error:&error]) {
        // Restore the link if moving the directory back fails, so the active
        // filesystem remains reachable rather than leaving a broken path.
        [manager createSymbolicLinkAtURL:dataURL withDestinationURL:visibleURL error:nil];
        NSLog(@"[iSH More] Cannot restore private data for root %@: %@", name, error);
        return NO;
    }
    NSLog(@"[iSH More] Restored inactive root %@ to its storage directory", name);
    return YES;
}

- (BOOL)exposeDataForRootName:(NSString *)name {
    if (name.length == 0)
        return NO;

    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *rootDirectory = [RootsDir() URLByAppendingPathComponent:name isDirectory:YES];
    NSURL *dataURL = [rootDirectory URLByAppendingPathComponent:@"data" isDirectory:YES];
    NSURL *visibleURL = DocumentsLinuxURL();
    if (visibleURL == nil)
        return NO;

    NSString *linkTarget = [manager destinationOfSymbolicLinkAtPath:dataURL.path error:nil];
    if (PathsEqual(linkTarget, visibleURL.path)) {
        if ([manager fileExistsAtPath:visibleURL.path])
            return YES;
        NSLog(@"[iSH More] Documents/Linux link exists but its target is missing: %@", visibleURL.path);
        return NO;
    }

    BOOL dataIsDirectory = NO;
    BOOL dataExists = [manager fileExistsAtPath:dataURL.path isDirectory:&dataIsDirectory] && dataIsDirectory;
    BOOL visibleExists = [manager fileExistsAtPath:visibleURL.path isDirectory:nil];

    // Recover a missing link when the visible root is already present.
    if (!dataExists && visibleExists) {
        NSError *linkError = nil;
        if ([manager createSymbolicLinkAtURL:dataURL withDestinationURL:visibleURL error:&linkError])
            return YES;
        NSLog(@"[iSH More] Cannot recreate Documents/Linux link: %@", linkError);
        return NO;
    }

    // Do not overwrite an existing Documents/Linux folder. It may contain
    // user data that does not belong to this filesystem.
    if (visibleExists) {
        NSLog(@"[iSH More] Not moving root %@ because Documents/Linux already exists", name);
        return NO;
    }
    if (!dataExists) {
        NSLog(@"[iSH More] No data directory to expose for root %@", name);
        return NO;
    }

    NSError *error = nil;
    if (![manager moveItemAtURL:dataURL toURL:visibleURL error:&error]) {
        NSLog(@"[iSH More] Could not move root %@ into Documents/Linux: %@", name, error);
        return NO;
    }

    error = nil;
    if (![manager createSymbolicLinkAtURL:dataURL withDestinationURL:visibleURL error:&error]) {
        // Roll back immediately if the symlink cannot be created.
        NSError *rollbackError = nil;
        [manager moveItemAtURL:visibleURL toURL:dataURL error:&rollbackError];
        NSLog(@"[iSH More] Could not link root %@ to Documents/Linux: %@ (rollback: %@)", name, error, rollbackError);
        return NO;
    }

    NSLog(@"[iSH More] Linux filesystem %@ is now visible at %@", name, visibleURL.path);
    return YES;
}

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
            NSError *importError = nil;
            if (![self importRootFromArchive:[NSBundle.mainBundle URLForResource:@"root" withExtension:@"tar.gz"]
                                        name:@"default"
                                       error:&importError
                            progressReporter:nil]) {
                NSAssert(NO, @"failed to import default root, error %@", importError);
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

        // Ensure the currently selected Linux root appears in the normal
        // "On My iPhone > iSH More" Documents location, not only themes/.
        if (self.defaultRoot.length > 0)
            [self exposeDataForRootName:self.defaultRoot];
    }
    return self;
}

- (NSString *)defaultRoot {
    return [NSUserDefaults.standardUserDefaults stringForKey:kDefaultRoot];
}
- (void)setDefaultRoot:(NSString *)defaultRoot {
    NSString *oldRoot = [NSUserDefaults.standardUserDefaults stringForKey:kDefaultRoot];
    if ([oldRoot isEqualToString:defaultRoot]) {
        if (defaultRoot.length > 0)
            [self exposeDataForRootName:defaultRoot];
        return;
    }

    // When the user switches filesystems, move the old active data directory
    // back to its private root folder before exposing the newly selected one.
    if (oldRoot.length > 0 && ![self restoreDataForRootName:oldRoot]) {
        NSLog(@"[iSH More] Keeping default root %@ because its data could not be restored safely", oldRoot);
        return;
    }

    [NSUserDefaults.standardUserDefaults setObject:defaultRoot forKey:kDefaultRoot];
    if (defaultRoot.length > 0)
        [self exposeDataForRootName:defaultRoot];
    [self syncFileProviderDomains];
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
