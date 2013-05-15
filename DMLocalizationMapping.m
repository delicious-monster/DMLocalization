//
//  DMLocalizationMapping.m
//  Library
//
//  Created by William Shipley on 5/15/13.
//  Copyright (c) 2013 Delicious Monster Software. All rights reserved.
//

#import "DMLocalizationMapping.h"

#import "DMFormatString.h"


@implementation DMLocalizationMapping {
    NSString *_name;
    NSMutableDictionary *_allMappings;
    NSMutableDictionary *_mappingsByTableName;
}

#pragma mark API

- (id)initWithName:(NSString *)mappingName;
{
    if (!(self = [super init]))
        return nil;
    _name = [mappingName copy];
    _allMappings = [NSMutableDictionary dictionary];
    _mappingsByTableName = [NSMutableDictionary dictionary];
    return self;
}

- (NSUInteger)count;
{ return _allMappings.count; }

static BOOL isBetterLocalization(DMFormatString *newLocalizedString, DMFormatString *previousString, DMFormatString *devFormatString)
{
    if (previousString) {
        if ([previousString isEqual:newLocalizedString])
            return NO;
        else if ([newLocalizedString isEqual:devFormatString])
            return NO; // A localized string that's the same as the source is probably unlocalized (so not preferred)
    }
    return YES;
}

- (void)addLocalization:(DMFormatString *)localizedFormatString forDevString:(DMFormatString *)devFormatString context:(NSString *)tableNameOrNil;
{
    if (isBetterLocalization(localizedFormatString, _allMappings[devFormatString], devFormatString))
        _allMappings[devFormatString] = localizedFormatString;

    if (!tableNameOrNil)
        return;
    NSMutableDictionary *table = _mappingsByTableName[tableNameOrNil];
    if (!table)
        _mappingsByTableName[tableNameOrNil] = (table = [NSMutableDictionary dictionary]);
    if (isBetterLocalization(localizedFormatString, table[devFormatString], devFormatString))
        table[devFormatString] = localizedFormatString;
}

- (DMFormatString *)bestLocalizedFormatStringForDevString:(DMFormatString *)devFormatString forContext:(NSString *)tableNameOrNil matchLevel:(out DMMatchLevel *)outMatchLevel;
{
    if (!devFormatString)
        return nil;
    DMFormatString *localizedFormatString = nil;
    if (tableNameOrNil) {
        localizedFormatString = (_mappingsByTableName[tableNameOrNil])[devFormatString];
        if (outMatchLevel) *outMatchLevel = DMMatchSameContext;
        if (localizedFormatString)
            return localizedFormatString;
    }

    localizedFormatString = _allMappings[devFormatString];
    if (outMatchLevel) *outMatchLevel = DMMatchDifferentContext;
    if (localizedFormatString)
        return localizedFormatString;

    if (outMatchLevel) *outMatchLevel = DMMatchNone;
    return nil;
}

@end
