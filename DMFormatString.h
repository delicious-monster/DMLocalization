//
//  DMFormatString.h
//  Library
//
//  Created by William Shipley on 5/15/13.
//  Copyright (c) 2013 Delicious Monster Software. All rights reserved.
//

#import <Foundation/Foundation.h>


@interface DMFormatString : NSObject <NSCopying>
- (id)initWithString:(NSString *)string;
- (NSString *)stringByMatchingFormatString:(DMFormatString *)targetFormatString;

@property (readonly, nonatomic) BOOL usesExplicitFormatSpecifierPositions;
@property (readonly, nonatomic) BOOL probablyNeedsNoLocalization;
@property (readonly, nonatomic, copy) NSArray *components;
@property (readonly, nonatomic, copy) NSDictionary *formatSpecifiersByPosition;
@end

