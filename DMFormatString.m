//
//  DMFormatString.m
//  DMLocalization
//
//  Created by Jonathon Mah on 2011-07-26.
//  Copyright (c) 2011 Delicious Monster Software.
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "DMFormatString.h"

#import "DMFormatSpecifier.h"


@implementation DMFormatString

@synthesize formatSpecifiersByPosition = _formatSpecifiersByPosition;

#pragma mark NSObject

- (NSUInteger)hash;
{
    // NSArray's hash just returns its length, which is useless here because we have thousands of objects, typically with lengths under 4.
    NSUInteger hashAcc = 0;
    for (id component in _components)
        hashAcc ^= [component hash];
    return hashAcc;
}

- (BOOL)isEqual:(id)other;
{
    if (self == other)
        return YES;
    if (![other isKindOfClass:[DMFormatString class]])
        return NO;
    DMFormatString *otherFormatString = other;
    return [_components isEqual:otherFormatString.components];
}

- (NSString *)description;
{ return [_components description]; }


#pragma mark NSCopying

- (id)copyWithZone:(NSZone *)zone;
{ return self; }


#pragma mark API

- (id)initWithString:(NSString *)string;
{
    NSParameterAssert(string);
    if (!(self = [super init]))
        return nil;

    NSMutableArray *componentAccumulator = [NSMutableArray array];
    NSMutableString *literalAccumulator = [NSMutableString string];

    NSScanner *scanner = [NSScanner scannerWithString:string];
    scanner.charactersToBeSkipped = nil;
    NSInteger specifierPosition = 1;
    while (![scanner isAtEnd]) {
        __autoreleasing NSString *matchString = nil;
        if ([scanner scanUpToString:@"%" intoString:&matchString]) {
            [literalAccumulator appendString:matchString];
            continue;
        }

        // Process a percent
        NSMutableString *formatSpecifierAccumulator = [NSMutableString string];
        if ([scanner scanString:@"%" intoString:&matchString])
            [formatSpecifierAccumulator appendString:matchString];
        if ([scanner scanString:@"%" intoString:&matchString]) {
            [formatSpecifierAccumulator appendString:matchString];
            // Not a format sequence; a literal '%'
            [literalAccumulator appendString:formatSpecifierAccumulator];
            continue;
        }

        // Processing a format sequence
        if (literalAccumulator.length)
            [componentAccumulator addObject:[literalAccumulator copy]], literalAccumulator = [NSMutableString string];

        /* Must match a format specifier here, or the string is invalid.
         * We know that the format specifier must end with a character in TERMINATING_CHARSET (from the
         * "String Format Specifiers" doc page), but one of these characters doesn't necessarily mark
         * the end of the specifier. Our strategy: Accumulate the scan until hitting one of these characters.
         * Try matching with the regular expression. If no match, scan until the next one and try again.
         */
        if ([scanner scanUpToCharactersFromSet:[DMFormatSpecifier terminatingCharacterSet] intoString:&matchString])
            [formatSpecifierAccumulator appendString:matchString];
        BOOL (^scanSingleCharacter)(void) = ^{
            if ([scanner isAtEnd]) return NO;
            [formatSpecifierAccumulator appendString:[scanner.string substringWithRange:NSMakeRange(scanner.scanLocation, 1)]];
            scanner.scanLocation += 1; return YES;
        };
        scanSingleCharacter();

        DMFormatSpecifier *formatSpecifier = nil;
        while (!(formatSpecifier = [[DMFormatSpecifier alloc] initWithString:formatSpecifierAccumulator positionIfImplicit:specifierPosition])) {
            if ([scanner scanUpToCharactersFromSet:[DMFormatSpecifier terminatingCharacterSet] intoString:&matchString])
                [formatSpecifierAccumulator appendString:matchString];
            if (!scanSingleCharacter())
                break;
        }

        if (formatSpecifier) {
            if (formatSpecifier.positionWasExplicit)
                _usesExplicitFormatSpecifierPositions = YES;
            [componentAccumulator addObject:formatSpecifier];
            specifierPosition++;
        } else
            return nil; // Malformed format string
    }
    if (literalAccumulator.length)
        [componentAccumulator addObject:[literalAccumulator copy]];
    _components = [componentAccumulator copy];

    BOOL hasBitsNeedingLocalization = NO;
    for (id component in _components)
        if ([component isKindOfClass:[NSString class]])
            if ([component rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].length > 0) {
                hasBitsNeedingLocalization = YES;
                break;
            }
    _probablyNeedsNoLocalization = !hasBitsNeedingLocalization;
    return self;
}

- (NSString *)stringByMatchingFormatString:(DMFormatString *)targetFormatString;
{
    NSMutableArray *matchedComponents = [NSMutableArray arrayWithCapacity:self.components.count];
    [self.components enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if ([obj isKindOfClass:[NSString class]])
            [matchedComponents addObject:obj];
        else if ([obj isKindOfClass:[DMFormatSpecifier class]]) {
            DMFormatSpecifier *targetSpecifier = targetFormatString.formatSpecifiersByPosition[[obj valueForKey:@"position"]];
            DMFormatSpecifier *chosenSpecifier = obj;
            if ([obj isEqual:targetSpecifier])
                chosenSpecifier = targetSpecifier;
            [matchedComponents addObject:(self.usesExplicitFormatSpecifierPositions ? chosenSpecifier.stringWithExplicitPosition : chosenSpecifier)];
        } else
            NSAssert(NO, @"Bad object in components array");
    }];
    return [matchedComponents componentsJoinedByString:@""];
}

- (NSDictionary *)formatSpecifiersByPosition;
{
    if (!_formatSpecifiersByPosition) {
        NSMutableDictionary *specifierMap = [NSMutableDictionary dictionary];
        for (id component in self.components)
            if ([component isKindOfClass:[DMFormatSpecifier class]])
                specifierMap[[component valueForKey:@"position"]] = component;
        _formatSpecifiersByPosition = [specifierMap copy];
    }
    return _formatSpecifiersByPosition;
}

@end
