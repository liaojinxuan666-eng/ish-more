//
//  AppGroup.m
//  iSH
//
//  Created by Theodore Dubois on 2/28/20.
//

#import "AppGroup.h"
#import <Foundation/Foundation.h>
#import <mach-o/ldsyms.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <dlfcn.h>

#define CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0
#define CSMAGIC_EMBEDDED_ENTITLEMENTS 0xfade7171

struct cs_blob_index {
    uint32_t type;
    uint32_t offset;
};

struct cs_superblob {
    uint32_t magic;
    uint32_t length;
    uint32_t count;
    struct cs_blob_index index[];
};

struct cs_entitlements {
    uint32_t magic;
    uint32_t length;
    char entitlements[];
};

static NSDictionary *AppEntitlements(void) {
    static NSDictionary *entitlements;
    if (entitlements != nil)
        return entitlements;

    // Inspired by codesign.c in Darwin sources for Security.framework

    const struct mach_header_64 *header = &_mh_execute_header;

    // Simulator executables have fake entitlements in the code signature. The real entitlements can be found in an __entitlements section.
    size_t entitlements_size;
    char *entitlements_data = (char *) getsectiondata(header, "__TEXT", "__entitlements", &entitlements_size);
    if (entitlements_data != NULL) {
        NSData *data = [NSData dataWithBytesNoCopy:entitlements_data
                                            length:entitlements_size
                                      freeWhenDone:NO];
        return entitlements = [NSPropertyListSerialization propertyListWithData:data
                                                                        options:NSPropertyListImmutable
                                                                         format:nil
                                                                          error:nil];
    }

    // Find the LC_CODE_SIGNATURE
    struct load_command *lc = (void *) (header + 1);
    struct linkedit_data_command *cs_lc = NULL;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (lc->cmd == LC_CODE_SIGNATURE) {
            cs_lc = (void *) lc;
            break;
        }
        lc = (void *) ((char *) lc + lc->cmdsize);
    }
    if (cs_lc == NULL)
        return nil;

    // Read the code signature off disk, as it's apparently not loaded into memory
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForReadingFromURL:NSBundle.mainBundle.executableURL error:nil];
    if (fileHandle == nil)
        return nil;
    [fileHandle seekToFileOffset:cs_lc->dataoff];
    NSData *csData = [fileHandle readDataOfLength:cs_lc->datasize];
    [fileHandle closeFile];

    // Do not trust offsets or lengths read from the code signature until they
    // have been checked. Unsigned/ad-hoc sideloaded builds may not contain the
    // entitlement blob this code expects.
    size_t headerLength = offsetof(struct cs_superblob, index);
    if (csData.length < headerLength)
        return nil;

    const struct cs_superblob *cs = csData.bytes;
    if (ntohl(cs->magic) != CSMAGIC_EMBEDDED_SIGNATURE)
        return nil;

    uint32_t superblobLength = ntohl(cs->length);
    uint32_t count = ntohl(cs->count);
    if (superblobLength < headerLength || superblobLength > csData.length ||
        count > (superblobLength - headerLength) / sizeof(struct cs_blob_index))
        return nil;

    // Find the entitlements in the code signature.
    NSData *entitlementsData = nil;
    size_t entitlementHeaderLength = offsetof(struct cs_entitlements, entitlements);
    for (uint32_t i = 0; i < count; i++) {
        uint32_t offset = ntohl(cs->index[i].offset);
        if (offset > superblobLength || entitlementHeaderLength > superblobLength - offset)
            continue;

        struct cs_entitlements *ents = (void *) ((char *) cs + offset);
        uint32_t blobLength = ntohl(ents->length);
        if (ntohl(ents->magic) == CSMAGIC_EMBEDDED_ENTITLEMENTS &&
            blobLength >= entitlementHeaderLength &&
            blobLength <= superblobLength - offset) {
            entitlementsData = [NSData dataWithBytes:ents->entitlements
                                              length:blobLength - entitlementHeaderLength];
            break;
        }
    }
    if (entitlementsData == nil)
        return nil;

    return entitlements = [NSPropertyListSerialization propertyListWithData:entitlementsData
                                                                    options:NSPropertyListImmutable
                                                                     format:nil
                                                                      error:nil];
}

NSArray<NSString *> *CurrentAppGroups(void) {
    id value = AppEntitlements()[@"com.apple.security.application-groups"];
    if (![value isKindOfClass:NSArray.class]) {
        NSLog(@"[iSH More] App Group entitlement is missing or unreadable");
        return @[];
    }

    NSMutableArray<NSString *> *groups = [NSMutableArray array];
    for (id candidate in (NSArray *)value) {
        if ([candidate isKindOfClass:NSString.class] && [candidate length] > 0)
            [groups addObject:candidate];
    }
    return groups;
}

NSURL *ContainerURL(void) {
    for (NSString *appGroup in CurrentAppGroups()) {
        NSURL *container = [NSFileManager.defaultManager
            containerURLForSecurityApplicationGroupIdentifier:appGroup];
        if (container != nil)
            return container;
        NSLog(@"[iSH More] App Group container is unavailable: %@", appGroup);
    }

    NSLog(@"[iSH More] No usable App Group container. Check the signed entitlements.");
    return nil;
}
