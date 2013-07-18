//
//  DMFormatSpecifier.h
//  Library
//
//  Created by William Shipley on 5/15/13.
//  Copyright (c) 2013 Delicious Monster Software. All rights reserved.
//

#import <Foundation/Foundation.h>


typedef enum {
    DMFormatSpecifierUnknownType = 0,
    DMFormatSpecifierFormatStringType,
    DMFormatSpecifierDisplayPatternType,
    DMFormatSpecifierRuleEditorType,
} DMFormatSpecifierType;

@interface DMFormatSpecifier : NSObject
+ (NSCharacterSet *)terminatingCharacterSet;
- (id)initWithString:(NSString *)potentialSpecifierString positionIfImplicit:(NSInteger)implicitPosition;
- (NSString *)stringWithExplicitPosition;
@property (readonly) DMFormatSpecifierType specifierType;
@property (readonly) NSInteger position; // 1-based
@property (readonly) BOOL positionWasExplicit;
@property (readonly, copy) NSString *specifierString; // Starts with %
@end

