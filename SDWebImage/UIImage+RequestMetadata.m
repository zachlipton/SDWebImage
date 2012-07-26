//
//  UIImage+RequestMetadata.m
//  SDWebImage
//
//  Created by Zach Lipton on 7/25/12.
//  Copyright (c) 2012 Dijit. All rights reserved.
//

#import "UIImage+RequestMetadata.h"

#define kImageMetadataIsCachedKey @"image_iscachedresponse"

@implementation UIImage (RequestMetadata)
- (BOOL)isCacheResponse {
    if (objc_getAssociatedObject(self, kImageMetadataIsCachedKey) != nil)
        return YES;
    return NO;
}

- (void)setIsCacheResponse:(bool)isCached {
    if (isCached)
        objc_setAssociatedObject(self, kImageMetadataIsCachedKey, [NSNumber numberWithBool:YES], OBJC_ASSOCIATION_RETAIN);
    else
        objc_setAssociatedObject(self, kImageMetadataIsCachedKey, nil, OBJC_ASSOCIATION_RETAIN);
}
@end
