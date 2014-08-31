//
//  DMStringsFileScanner.m
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

#import "DMStringsFileScanner.h"


typedef enum {
    DMStateExpectingKey,
    DMStateExpectingEquals,
    DMStateExpectingValue,
    DMStateExpectingSemicolon,
} DMParseState;


@implementation DMStringsFileScanner {
    DMParseState _parseState;
    NSScanner *_scanner; // Must compose because NSScanner is a class cluster
}

#pragma mark NSScanner

- (id)initWithString:(NSString *)string;
{
    if (!(self = [super initWithString:@""]))
        return nil;
    _scanner = [[NSScanner alloc] initWithString:string];
    self.charactersToBeSkipped = nil;
    _parseState = DMStateExpectingKey;
    return self;
}

// NSScanner bullshit
- (NSString *)string;
{ return _scanner.string; }
- (NSUInteger)scanLocation;
{ return [_scanner scanLocation]; }
- (void)setScanLocation:(NSUInteger)pos;
{ [_scanner setScanLocation:pos]; }
- (BOOL)caseSensitive;
{ return [_scanner caseSensitive]; }
- (void)setCaseSensitive:(BOOL)flag;
{ [_scanner setCaseSensitive:flag]; }
- (NSCharacterSet *)charactersToBeSkipped;
{ return [_scanner charactersToBeSkipped]; }
- (void)setCharactersToBeSkipped:(NSCharacterSet *)set;
{ [_scanner setCharactersToBeSkipped:set]; }
- (id)locale;
{ return [_scanner locale]; }
- (void)setLocale:(id)locale;
{ [_scanner setLocale:locale]; }


#pragma mark API

- (BOOL)scanNextValidStringsTokenIntoString:(out NSString **)outString tokenType:(out DMStringsFileTokenType *)outTokenType stringQuoted:(out BOOL *)outStringIsQuoted;
{
    if ([self isAtEnd])
        return NO;
    __autoreleasing NSString *matchString = nil;

    // Maybe scan comment
    if ([self scanCommentIntoString:&matchString]) {
        if (outTokenType) *outTokenType = DMStringsFileTokenComment;
        if (outString) *outString = matchString;
        return YES;
    }

    // Maybe scan whitespace (outside of anything else)
    if ([_scanner scanCharactersFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet] intoString:&matchString]) {
        if (outTokenType) *outTokenType = DMStringsFileTokenWhitespace;
        if (outString) *outString = matchString;
        return YES;
    }

    // Scan content
    switch (_parseState) {
        case DMStateExpectingKey:
        case DMStateExpectingValue: {
            // Read a quoted or unquoted string
            BOOL stringTokenQuoted = YES;
            if ([self scanPossiblyQuotedStringIntoString:&matchString quoted:&stringTokenQuoted]) {
                if (outTokenType) *outTokenType = (_parseState == DMStateExpectingKey) ? DMStringsFileTokenKeyString : DMStringsFileTokenValueString;
                if (outString) *outString = matchString;
                if (outStringIsQuoted) *outStringIsQuoted = stringTokenQuoted;
                _parseState++;
                return YES;
            } else
                return NO;
        }
        case DMStateExpectingEquals:
            if ([_scanner scanString:@"=" intoString:&matchString]) {
                if (outTokenType) *outTokenType = DMStringsFileTokenPairSeparator;
                if (outString) *outString = matchString;
                _parseState++;
                return YES;
            } else
                return NO;
        case DMStateExpectingSemicolon:
            if ([_scanner scanString:@";" intoString:&matchString]) {
                if (outTokenType) *outTokenType = DMStringsFileTokenPairTerminator;
                if (outString) *outString = matchString;
                _parseState = DMStateExpectingKey;
                return YES;
            } else
                return NO;
    }
    return NO;
}

- (BOOL)scanCommentIntoString:(out NSString **)outString;
{
    static NSString *startComment = @"/*", *endComment = @"*/";
    __autoreleasing NSString *matchString;

    if ([_scanner scanString:startComment intoString:&matchString]) {
        NSMutableString *accumulator = [NSMutableString string];
        [accumulator appendString:matchString];
        if ([_scanner scanUpToString:endComment intoString:&matchString])
            [accumulator appendString:matchString];
        if ([_scanner scanString:endComment intoString:&matchString])
            [accumulator appendString:matchString];
        else {
            fputs([[NSString stringWithFormat:@"%@: Error: Expected to read \"%@\"\n", self.filePathForErrorLog, endComment] UTF8String], stderr);
            return NO;
        }
        if (outString)
            *outString = accumulator;
        return YES;
    }
    return NO;
}

- (BOOL)scanPossiblyQuotedStringIntoString:(out NSString **)outString quoted:(out BOOL *)outStringIsQuoted;
{
    static dispatch_once_t onceToken;
    static NSCharacterSet *maybeEndQuotedStringSet;
    dispatch_once(&onceToken, ^{
        maybeEndQuotedStringSet = [NSCharacterSet characterSetWithCharactersInString:@"\\\""]; // Double-quote or backslash
    });
    __autoreleasing NSString *matchString;

    NSString *stringToken = nil;
    if ([_scanner scanString:@"\"" intoString:&matchString]) {
        NSMutableString *quotedString = [NSMutableString string];
        [quotedString appendString:matchString];
        BOOL quotedStringTerminated = NO;
        while (!quotedStringTerminated && ![self isAtEnd]) {
            if ([_scanner scanUpToCharactersFromSet:maybeEndQuotedStringSet intoString:&matchString])
                [quotedString appendString:matchString];

            if ([_scanner scanString:@"\"" intoString:&matchString]) // Final quote
                [quotedString appendString:matchString], quotedStringTerminated = YES;
            else if ([_scanner scanString:@"\\" intoString:&matchString]) { // Skip the backslash and the next character
                [quotedString appendString:matchString];
                if ([self isAtEnd]) break;
                NSString *followingCharacterString = [self.string substringWithRange:NSMakeRange(self.scanLocation, 1)];
                [quotedString appendString:followingCharacterString];
                self.scanLocation += 1;
            } else
                break;
        }

        if (quotedStringTerminated) {
            stringToken = quotedString;
            if (outStringIsQuoted) *outStringIsQuoted = YES;
        } else
            fputs([[NSString stringWithFormat:@"%@: Error: Unterminated string: %@\n", self.filePathForErrorLog, [quotedString substringToIndex:MIN(quotedString.length, 10u)]] UTF8String], stderr);
    } else if ([_scanner scanUpToCharactersFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet] intoString:&matchString]) {
        stringToken = matchString;
        if (outStringIsQuoted) *outStringIsQuoted = NO;
    }

    if (stringToken && outString)
        *outString = stringToken;
    return (stringToken != nil);
}

+ (NSString *)unquotedString:(NSString *)stringMaybeWithQuotes if:(BOOL)flag;
{
    return flag ? [stringMaybeWithQuotes substringWithRange:NSMakeRange(1, stringMaybeWithQuotes.length - 2)] : stringMaybeWithQuotes;
}

@end
