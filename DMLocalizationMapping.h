//
//  DMLocalizationMapping.h
//  Library
//
//  Created by William Shipley on 5/15/13.
//  Copyright (c) 2013 Delicious Monster Software. All rights reserved.
//

#import <Foundation/Foundation.h>

@class DMFormatString;

typedef enum {
    DMMatchSameContext,
    DMMatchDifferentContext,
    DMMatchNone,
} DMMatchLevel;

@interface DMLocalizationMapping : NSObject

// Strings stored here should have the necessary characters escaped (specifically double-quotes)
- (id)initWithName:(NSString *)mappingName; // Name just for debugging
- (NSUInteger)count;
- (void)addLocalization:(DMFormatString *)localizedFormatString forDevString:(DMFormatString *)devFormatString context:(NSString *)tableNameOrNil;
- (DMFormatString *)bestLocalizedFormatStringForDevString:(DMFormatString *)devFormatString forContext:(NSString *)tableNameOrNil matchLevel:(out DMMatchLevel *)outMatchLevel;

@end
