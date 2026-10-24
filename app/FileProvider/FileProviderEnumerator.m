//
//  FileProviderEnumerator.m
//  iSHFiles
//
//  Refresh-aware directory enumerator for iSH More.
//

#import <MobileCoreServices/MobileCoreServices.h>
#import <dispatch/dispatch.h>
#include <dirent.h>
#include <sys/event.h>
#import "FileProviderExtension.h"
#import "FileProviderEnumerator.h"
#import "FileProviderItem.h"
#import "NSError+ISHErrno.h"
#include "fs/fake-db.h"

@interface FileProviderEnumerator ()
@property (nonatomic, strong) FileProviderItem *item;
@property (nonatomic, strong) NSMutableSet<NSString *> *knownChildIdentifiers;
@property (nonatomic, strong) dispatch_source_t directoryWatcher;
@property (nonatomic) uint64_t syncAnchorValue;
@end

@implementation FileProviderEnumerator

- (instancetype)initWithItem:(FileProviderItem *)item {
    if (self = [super init]) {
        self.item = item;
        self.knownChildIdentifiers = [NSMutableSet new];
        [self startWatchingDirectory];
    }
    return self;
}

// The backing directory is shared with the terminal process. Watching it lets
// the File Provider tell Files.app when a command such as mkdir creates an item.
- (void)startWatchingDirectory {
    if (self.item == nil ||
        ![self.item.typeIdentifier isEqualToString:(NSString *)kUTTypeFolder])
        return;

    NSError *error = nil;
    int fd = [self.item openNewFDWithError:&error];
    if (fd < 0) {
        NSLog(@"[iSH More] Could not watch %@: %@", self.item.path, error);
        return;
    }

    // Vnode dispatch sources use NOTE_* masks from <sys/event.h>.
    unsigned long mask = NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_ATTRIB;
    dispatch_source_t source = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_VNODE,
        (uintptr_t)fd,
        mask,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (source == nil) {
        close(fd);
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.item == nil)
            return;

        NSFileProviderItemIdentifier identifier = strongSelf.item.itemIdentifier;
        [[NSFileProviderManager defaultManager]
            signalEnumeratorForContainerItemIdentifier:identifier
                                     completionHandler:^(NSError *signalError) {
            if (signalError != nil)
                NSLog(@"[iSH More] Failed to signal folder refresh %@: %@", identifier, signalError);
        }];
    });
    dispatch_source_set_cancel_handler(source, ^{
        close(fd);
    });

    self.directoryWatcher = source;
    dispatch_resume(source);
}

// Returns the current children and their stable File Provider identifiers.
- (NSArray<FileProviderItem *> *)readChildrenAndIdentifiers:(NSMutableSet<NSString *> *)identifiers
                                                      error:(NSError **)error {
    if (self.item == nil) {
        if (error != NULL)
            *error = [NSError errorWithDomain:NSFileProviderErrorDomain
                                         code:NSFileProviderErrorNotAuthenticated
                                     userInfo:nil];
        return nil;
    }

    int fd = [self.item openNewFDWithError:error];
    if (fd == -1)
        return nil;

    DIR *dir = fdopendir(fd);
    if (dir == NULL) {
        int savedErrno = errno;
        close(fd);
        if (error != NULL)
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:savedErrno userInfo:nil];
        return nil;
    }

    NSMutableArray<FileProviderItem *> *items = [NSMutableArray new];
    NSString *parentPath = self.item.path;
    struct dirent *entry;
    int readError = 0;

    while (YES) {
        errno = 0;
        entry = readdir(dir);
        if (entry == NULL) {
            readError = errno;
            break;
        }

        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;

        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        NSString *childPath = [parentPath stringByAppendingFormat:@"/%@", name];
        db_begin_read(&self.item.mount->db);
        inode_t inode = path_get_inode(&self.item.mount->db, childPath.fileSystemRepresentation);
        db_commit(&self.item.mount->db);

        if (inode == 0) {
            // The host directory and fakefs database can briefly disagree while
            // a command is creating/removing a file. Ignore it and retry next refresh.
            continue;
        }

        NSString *childIdentifier = [NSString stringWithFormat:@"%llu", (unsigned long long)inode];
        NSError *itemError = nil;
        FileProviderItem *child = [[FileProviderItem alloc] initWithIdentifier:childIdentifier
                                                                          mount:self.item.mount
                                                                          error:&itemError];
        if (child == nil) {
            closedir(dir);
            if (error != NULL)
                *error = itemError;
            return nil;
        }

        [items addObject:child];
        [identifiers addObject:childIdentifier];
    }

    closedir(dir);
    if (readError != 0) {
        if (error != NULL)
            *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:readError userInfo:nil];
        return nil;
    }
    return items;
}

- (void)enumerateItemsForObserver:(id<NSFileProviderEnumerationObserver>)observer
                   startingAtPage:(NSFileProviderPage)page {
    NSLog(@"[iSH More] Enumerating %@", self.item.itemIdentifier);
    if (self.item == nil) {
        [observer finishEnumeratingUpToPage:page];
        return;
    }

    if (![self.item.typeIdentifier isEqualToString:(NSString *)kUTTypeFolder]) {
        [observer finishEnumeratingUpToPage:page];
        return;
    }

    NSMutableSet<NSString *> *identifiers = [NSMutableSet new];
    NSError *error = nil;
    NSArray<FileProviderItem *> *items = [self readChildrenAndIdentifiers:identifiers error:&error];
    if (items == nil) {
        [observer finishEnumeratingWithError:error ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil]];
        return;
    }

    @synchronized (self) {
        self.knownChildIdentifiers = identifiers;
    }
    [observer didEnumerateItems:items];
    [observer finishEnumeratingUpToPage:nil];
}

- (void)enumerateChangesForObserver:(id<NSFileProviderChangeObserver>)observer
                     fromSyncAnchor:(NSFileProviderSyncAnchor)anchor {
    if (self.item == nil) {
        [observer finishEnumeratingWithError:[NSError errorWithDomain:NSFileProviderErrorDomain
                                                                  code:NSFileProviderErrorNotAuthenticated
                                                              userInfo:nil]];
        return;
    }

    NSMutableSet<NSString *> *currentIdentifiers = [NSMutableSet new];
    NSError *error = nil;
    NSArray<FileProviderItem *> *items = [self readChildrenAndIdentifiers:currentIdentifiers error:&error];
    if (items == nil) {
        [observer finishEnumeratingWithError:error ?: [NSError errorWithDomain:NSPOSIXErrorDomain code:EIO userInfo:nil]];
        return;
    }

    NSMutableSet<NSString *> *deletedIdentifiers = [NSMutableSet new];
    @synchronized (self) {
        [deletedIdentifiers unionSet:self.knownChildIdentifiers];
        [deletedIdentifiers minusSet:currentIdentifiers];
        self.knownChildIdentifiers = currentIdentifiers;
        self.syncAnchorValue += 1;
    }

    if (deletedIdentifiers.count > 0)
        [observer didDeleteItemsWithIdentifiers:deletedIdentifiers.allObjects];

    // Return a fresh metadata snapshot. This also updates size/date metadata for
    // already-known files, while the identifier set detects removed children.
    if (items.count > 0)
        [observer didUpdateItems:items];

    [observer finishEnumeratingChangesUpToSyncAnchor:[self currentAnchorData] moreComing:NO];
}

- (NSData *)currentAnchorData {
    uint64_t value;
    @synchronized (self) {
        value = self.syncAnchorValue;
    }
    return [NSData dataWithBytes:&value length:sizeof(value)];
}

- (void)currentSyncAnchorWithCompletionHandler:(void (^)(NSFileProviderSyncAnchor currentAnchor))completionHandler {
    completionHandler([self currentAnchorData]);
}

- (void)invalidate {
    dispatch_source_t watcher = self.directoryWatcher;
    if (watcher != nil) {
        dispatch_source_cancel(watcher);
        self.directoryWatcher = nil;
    }
    self.item = nil;
}

@end
