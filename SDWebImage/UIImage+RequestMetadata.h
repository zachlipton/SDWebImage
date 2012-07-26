//
//  UIImage+RequestMetadata.h
//  SDWebImage
//
//  Created by Zach Lipton on 7/25/12.
//  Copyright (c) 2012 Dijit. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface UIImage (RequestMetadata)
- (BOOL)isCacheResponse;
- (void)setIsCacheResponse:(bool)isCached;
@end
