/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDImageCache.h"
#import "SDWebImageDecoder.h"
#import <CommonCrypto/CommonDigest.h>

#ifdef ENABLE_SDWEBIMAGE_DECODER
#import "SDWebImageDecoder.h"
#endif

static unsigned long long MAX_DISK_USAGE = 200 * 1024 * 1024ULL;

static SDImageCache *instance;

@implementation SDImageCache

#pragma mark NSObject

- (id)init
{
    if ((self = [super init]))
    {
        // Init the memory cache
        memCache = [[NSMutableDictionary alloc] init];

        // Init the disk cache
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
        diskCachePath = [[[paths objectAtIndex:0] stringByAppendingPathComponent:@"ImageCache"] retain];

        if (![[NSFileManager defaultManager] fileExistsAtPath:diskCachePath])
        {
            [[NSFileManager defaultManager] createDirectoryAtPath:diskCachePath
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:NULL];
        }

        // Init the operation queue
        cacheInQueue = [[NSOperationQueue alloc] init];
        cacheInQueue.maxConcurrentOperationCount = 1;
        cacheOutQueue = [[NSOperationQueue alloc] init];
        cacheOutQueue.maxConcurrentOperationCount = 1;

#if TARGET_OS_IPHONE
        // Subscribe to app events
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clearMemory)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];

#if __IPHONE_OS_VERSION_MIN_REQUIRED >= __IPHONE_4_0
        UIDevice *device = [UIDevice currentDevice];
        if ([device respondsToSelector:@selector(isMultitaskingSupported)] && device.multitaskingSupported)
        {
            // When in background, clean memory in order to have less chance to be killed
            [[NSNotificationCenter defaultCenter] addObserver:self
                                                     selector:@selector(clearMemory)
                                                         name:UIApplicationDidEnterBackgroundNotification
                                                       object:nil];
        }
#endif
#endif

        // Determine initial disk usage, clean if necessary
        diskUsage = [self findDiskUsage];
        [self cleanDisk];
    }

    return self;
}

- (void)dealloc
{
    [memCache release], memCache = nil;
    [diskCachePath release], diskCachePath = nil;
    [cacheInQueue release], cacheInQueue = nil;

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [super dealloc];
}

#pragma mark SDImageCache (class methods)

+ (SDImageCache *)sharedImageCache
{
    if (instance == nil)
    {
        instance = [[SDImageCache alloc] init];
    }

    return instance;
}

#pragma mark SDImageCache (private)

- (NSString *)cachePathForKey:(NSString *)key
{
    const char *str = [key UTF8String];
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), r);
    NSString *filename = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
                          r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12], r[13], r[14], r[15]];

    return [diskCachePath stringByAppendingPathComponent:filename];
}

- (void)storeKeyWithDataToDisk:(NSArray *)keyAndData
{
    // Can't use defaultManager another thread
    NSFileManager *fileManager = [[NSFileManager alloc] init];

    NSString *key = [keyAndData objectAtIndex:0];
    NSData *data = [keyAndData count] > 1 ? [keyAndData objectAtIndex:1] : nil;

    if (data)
    {
        if ([fileManager createFileAtPath:[self cachePathForKey:key] contents:data attributes:nil])
        {
            diskUsage += [data length];
        }
    }
    else
    {
        // If no data representation given, convert the UIImage in JPEG and store it
        // This trick is more CPU/memory intensive and doesn't preserve alpha channel
        UIImage *image = [[self imageFromKey:key fromDisk:YES] retain]; // be thread safe with no lock
        if (image)
        {
#if TARGET_OS_IPHONE
            NSData* jpegData = UIImageJPEGRepresentation(image, (CGFloat)1.0);
            BOOL created = [fileManager createFileAtPath:[self cachePathForKey:key] contents:jpegData attributes:nil];
#else
            NSArray*  representations  = [image representations];
            NSData* jpegData = [NSBitmapImageRep representationOfImageRepsInArray: representations usingType: NSJPEGFileType properties:nil];
            BOOL created = [fileManager createFileAtPath:[self cachePathForKey:key] contents:jpegData attributes:nil];
#endif
            if (created)
            {
                diskUsage += [jpegData length];
            }
            [image release];
        }
    }

    [self cleanDisk];

    [fileManager release];
}

- (void)notifyDelegate:(NSDictionary *)arguments
{
    NSString *key = [arguments objectForKey:@"key"];
    id <SDImageCacheDelegate> delegate = [arguments objectForKey:@"delegate"];
    NSDictionary *info = [arguments objectForKey:@"userInfo"];
    UIImage *image = [arguments objectForKey:@"image"];

    if (image)
    {
        [memCache setObject:image forKey:key];

        if ([delegate respondsToSelector:@selector(imageCache:didFindImage:forKey:userInfo:)])
        {
            [delegate imageCache:self didFindImage:image forKey:key userInfo:info];
        }
    }
    else
    {
        if ([delegate respondsToSelector:@selector(imageCache:didNotFindImageForKey:userInfo:)])
        {
            [delegate imageCache:self didNotFindImageForKey:key userInfo:info];
        }
    }
}

- (void)queryDiskCacheOperation:(NSDictionary *)arguments
{
    NSString *key = [arguments objectForKey:@"key"];
    NSMutableDictionary *mutableArguments = [[arguments mutableCopy] autorelease];

    UIImage *image = [[[UIImage alloc] initWithContentsOfFile:[self cachePathForKey:key]] autorelease];
    if (image)
    {
#ifdef ENABLE_SDWEBIMAGE_DECODER
        UIImage *decodedImage = [UIImage decodedImageWithImage:image];
        if (decodedImage)
        {
            image = decodedImage;
        }
#endif
        [mutableArguments setObject:image forKey:@"image"];
    }

    [self performSelectorOnMainThread:@selector(notifyDelegate:) withObject:mutableArguments waitUntilDone:NO];
}

#pragma mark ImageCache

- (void)storeImage:(UIImage *)image imageData:(NSData *)data forKey:(NSString *)key toDisk:(BOOL)toDisk
{
    if (!image || !key)
    {
        return;
    }

    [memCache setObject:image forKey:key];

    if (toDisk)
    {
        if (!data) return;
        NSArray *keyWithData;
        if (data)
        {
            keyWithData = [NSArray arrayWithObjects:key, data, nil];
        }
        else
        {
            keyWithData = [NSArray arrayWithObjects:key, nil];
        }
        [cacheInQueue addOperation:[[[NSInvocationOperation alloc] initWithTarget:self
                                                                         selector:@selector(storeKeyWithDataToDisk:)
                                                                           object:keyWithData] autorelease]];
    }
}

- (void)storeImage:(UIImage *)image forKey:(NSString *)key
{
    [self storeImage:image imageData:nil forKey:key toDisk:YES];
}

- (void)storeImage:(UIImage *)image forKey:(NSString *)key toDisk:(BOOL)toDisk
{
    [self storeImage:image imageData:nil forKey:key toDisk:toDisk];
}


- (UIImage *)imageFromKey:(NSString *)key
{
    return [self imageFromKey:key fromDisk:YES];
}

- (UIImage *)imageFromKey:(NSString *)key fromDisk:(BOOL)fromDisk
{
    if (key == nil)
    {
        return nil;
    }

    UIImage *image = [memCache objectForKey:key];

    if (!image && fromDisk)
    {
        image = [[[UIImage alloc] initWithContentsOfFile:[self cachePathForKey:key]] autorelease];
        if (image)
        {
            [memCache setObject:image forKey:key];
        }
    }

    return image;
}

- (void)queryDiskCacheForKey:(NSString *)key delegate:(id <SDImageCacheDelegate>)delegate userInfo:(NSDictionary *)info
{
    if (!delegate)
    {
        return;
    }

    if (!key)
    {
        if ([delegate respondsToSelector:@selector(imageCache:didNotFindImageForKey:userInfo:)])
        {
            [delegate imageCache:self didNotFindImageForKey:key userInfo:info];
        }
        return;
    }

    // First check the in-memory cache...
    UIImage *image = [memCache objectForKey:key];
    if (image)
    {
        // ...notify delegate immediately, no need to go async
        if ([delegate respondsToSelector:@selector(imageCache:didFindImage:forKey:userInfo:)])
        {
            [delegate imageCache:self didFindImage:image forKey:key userInfo:info];
        }
        return;
    }

    NSMutableDictionary *arguments = [NSMutableDictionary dictionaryWithCapacity:3];
    [arguments setObject:key forKey:@"key"];
    [arguments setObject:delegate forKey:@"delegate"];
    if (info)
    {
        [arguments setObject:info forKey:@"userInfo"];
    }
    [cacheOutQueue addOperation:[[[NSInvocationOperation alloc] initWithTarget:self selector:@selector(queryDiskCacheOperation:) object:arguments] autorelease]];
}

- (void)removeImageForKey:(NSString *)key
{
    if (key == nil)
    {
        return;
    }

    [memCache removeObjectForKey:key];
    [[NSFileManager defaultManager] removeItemAtPath:[self cachePathForKey:key] error:nil];
}

- (void)clearMemory
{
    [cacheInQueue cancelAllOperations]; // won't be able to complete
    [memCache removeAllObjects];
}

- (void)clearDisk
{
    [cacheInQueue cancelAllOperations];
    [[NSFileManager defaultManager] removeItemAtPath:diskCachePath error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:diskCachePath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
}

- (void)cleanDisk
{
    if (diskUsage <= MAX_DISK_USAGE)
    {
        return;
    }

    // Delete cached files that were written cacheMaxCacheAge or more seconds ago
    NSFileManager* manager = [NSFileManager defaultManager];
    NSDirectoryEnumerator* fileEnumerator = [manager enumeratorAtPath:diskCachePath];
    NSMutableArray* fileInfos = [NSMutableArray array];
    for (NSString* fileName in fileEnumerator)
    {
        NSString* filePath = [diskCachePath stringByAppendingPathComponent:fileName];
        NSDictionary* attributes = [manager attributesOfItemAtPath:filePath error:nil];
        NSDictionary* info = [[NSDictionary alloc] initWithObjectsAndKeys:
                              filePath, @"path",
                              [attributes fileModificationDate], @"date",
                              [NSNumber numberWithUnsignedLongLong:[attributes fileSize]], @"size",
                              nil];
        [fileInfos addObject:info];
        [info release];
    }
    
    // Sort fileInfos array so oldest-created is first
    [fileInfos sortUsingComparator:^(id obj1, id obj2) {
        return [[obj1 objectForKey:@"date"] compare:[obj2 objectForKey:@"date"]];
    }];

    // Delete from oldest till we've reduce disk usage to half MAX_DISK_USAGE bytes
    unsigned long long diskUsageBefore = diskUsage;
    for (NSDictionary* info in fileInfos)
    {
        if (diskUsage <= MAX_DISK_USAGE / 2)
        {
            break;
        }
        if ([manager removeItemAtPath:[info objectForKey:@"path"] error:nil])
        {
            NSNumber* fileSize = [info objectForKey:@"size"];
            diskUsage -= [fileSize unsignedLongLongValue];
        }
    }

    NSLog(@"Cache disk usage reached %llu KB, cleaned to %llu KB",
          diskUsageBefore / 1024,
          diskUsage / 1024);
}

- (unsigned long long)findDiskUsage
{
    // Iterate through cache directory and sum file sizes of all files in cache
    NSFileManager* manager = [NSFileManager defaultManager];
    NSDirectoryEnumerator* fileEnumerator = [manager enumeratorAtPath:diskCachePath];
    unsigned long long usage = 0;
    for (NSString *fileName in fileEnumerator)
    {
        NSString *filePath = [diskCachePath stringByAppendingPathComponent:fileName];
        NSDictionary *attributes = [manager attributesOfItemAtPath:filePath error:nil];
        usage += [attributes fileSize];
    }
    return usage;
}

@end
