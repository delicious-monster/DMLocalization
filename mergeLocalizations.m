//
//  main.m
//  mergeLocalizations
//
//  Created by Jonathon Mah on 2011-07-25.
//  Copyright 2011 Delicious Monster Software. All rights reserved.
//

#import <Foundation/Foundation.h>


typedef enum {
    DMStringsFileTokenComment,
    DMStringsFileTokenWhitespace,
    DMStringsFileTokenKeyString,
    DMStringsFileTokenPairSeparator,
    DMStringsFileTokenValueString,
    DMStringsFileTokenPairTerminator,
} DMStringsFileTokenType;

@interface DMStringsFileScanner : NSScanner
@property (nonatomic, copy) NSString *filePathForErrorLog;
- (BOOL)scanNextValidStringsTokenIntoString:(out NSString **)outString tokenType:(out DMStringsFileTokenType *)outTokenType stringQuoted:(out BOOL *)outStringIsQuoted;
- (BOOL)scanCommentIntoString:(out NSString **)outString;
- (BOOL)scanPossiblyQuotedStringIntoString:(out NSString **)outString quoted:(out BOOL *)outStringIsQuoted;
+ (NSString *)unquotedString:(NSString *)stringMaybeWithQuotes if:(BOOL)flag;
@end

@interface DMFormatString : NSObject <NSCopying>
- (id)initWithString:(NSString *)string;
- (NSString *)stringByMatchingFormatString:(DMFormatString *)targetFormatString;
@property (readonly, nonatomic) BOOL usesExplicitFormatSpecifierPositions;
@property (readonly, nonatomic) BOOL probablyNeedsNoLocalization;
@property (readonly, nonatomic, copy) NSArray *components;
@property (readonly, nonatomic, copy) NSDictionary *formatSpecifiersByPosition;
@end

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


//#define SET_NEEDS_LOCALIZATION_IF_SAME_AS_DEV_STRING
static NSString *const DMOrphanedStringsFilename = @"_orphaned.strings";
static NSString *const DMDoNotLocalizeMarker = @"??";
static NSString *const DMNeedsLocalizationMarker = @" /*!!! Needs translation, delete this comment when translated !!!*/";
static NSString *const DMLocalizationOutOfContextMarker = @" /*!!! Translation found in different context, delete this comment if ok !!!*/";


int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *env = [[NSProcessInfo processInfo] environment];
        
        // Set paths
        NSString *resourcesPath, *sourcePath, *devLanguageLproj;
        if (env[@"TARGET_BUILD_DIR"]) {
            resourcesPath = [env[@"TARGET_BUILD_DIR"] stringByAppendingPathComponent:env[@"UNLOCALIZED_RESOURCES_FOLDER_PATH"]];
            sourcePath = env[@"SRCROOT"];
            devLanguageLproj = [env[@"DEVELOPMENT_LANGUAGE"] stringByAppendingPathExtension:@"lproj"];
        } else {
            resourcesPath = [@"~/Library/Developer/Xcode/DerivedData/UberLibrary-djzgxxrdrlqezxgaansiwhdraxmn/Build/Products/Debug/Delicious Library 3.app/Contents/Resources" stringByExpandingTildeInPath];
            sourcePath = [@"~/Documents/Streams/Delicious Monster/UberLibrary/Library" stringByExpandingTildeInPath];
            devLanguageLproj = @"en.lproj";
        }
        
        if (![fm fileExistsAtPath:resourcesPath] || ![fm fileExistsAtPath:sourcePath]) {
            fputs([[NSString stringWithFormat:@"Error: Resources and source directories must exist (%@ and %@)\n", resourcesPath, sourcePath] UTF8String], stderr);
            exit(EXIT_FAILURE);
        }
        
        // Build index of strings files in the development language, and the target translation languages
        NSMutableSet *devLanguageStringsFiles = [NSMutableSet set];
        for (NSString *languageSubfile in [fm contentsOfDirectoryAtPath:[resourcesPath stringByAppendingPathComponent:devLanguageLproj] error:NULL])
            if ([languageSubfile.pathExtension isEqual:@"strings"])
                [devLanguageStringsFiles addObject:languageSubfile];
        
        NSMutableSet *targetLanguageLprojs = [NSMutableSet set]; {
            __autoreleasing NSError *traverseError = nil;
            NSArray *sourceContents = [fm contentsOfDirectoryAtPath:sourcePath error:&traverseError];
            if (!sourceContents) {
                fputs([[NSString stringWithFormat:@"Error: Unable to list contents of directory at %@: %@\n", sourcePath, traverseError] UTF8String], stderr);
                exit(EXIT_FAILURE);
            }
            for (NSString *sourcePathComponent in sourceContents)
                if ([sourcePathComponent.pathExtension isEqual:@"lproj"] && ![sourcePathComponent isEqual:devLanguageLproj])
                    [targetLanguageLprojs addObject:sourcePathComponent];
        }
        
        /*
         * First, for each language, build a DMLocalizationMapping of each key-value pair,
         * also storing the name of the strings file in which each pair was found.
         */
        fputs([@"Building translation tables\n" UTF8String], stdout);
        BOOL hadParseError = NO;
        NSCharacterSet *charactersToTrim = [NSCharacterSet characterSetWithCharactersInString:@"\u261b\u261e"]; // Clean up legacy translation markers ("hand" characters)
        NSMutableDictionary *translationTables = [NSMutableDictionary new]; // lang.lproj to DMLocalizationMapping
        NSMutableDictionary *unusedLocalizations = [NSMutableDictionary new]; // lang.lproj to NSMutableSet of DMFormatString
        
        for (NSString *lproj in targetLanguageLprojs) {
            DMLocalizationMapping *mapping = [[DMLocalizationMapping alloc] initWithName:lproj];
            translationTables[lproj] = mapping;
            NSMutableSet *localizationKeys = [NSMutableSet set];
            unusedLocalizations[lproj] = localizationKeys;
            
            NSString *langaugeProjPath = [sourcePath stringByAppendingPathComponent:lproj];
            for (NSString *languageSubfile in [fm contentsOfDirectoryAtPath:langaugeProjPath error:NULL]) {
                if (![languageSubfile.pathExtension isEqual:@"strings"])
                    continue;
                NSString *stringsPath = [langaugeProjPath stringByAppendingPathComponent:languageSubfile];
                NSString *stringsContents = [NSString stringWithContentsOfFile:stringsPath usedEncoding:NULL error:NULL];
                if (!stringsContents) {
                    fputs([[NSString stringWithFormat:@"%@: Error: Unable to read strings file\n", stringsPath] UTF8String], stderr);
                    hadParseError = YES;
                    continue;
                }
                
                DMStringsFileScanner *scanner = [[DMStringsFileScanner alloc] initWithString:stringsContents];
                scanner.filePathForErrorLog = stringsPath;
                
                NSString *lastLocalizedString = nil;
                DMFormatString *lastDevFormatString = nil, *lastLocalizedFormatString = nil;
                while (![scanner isAtEnd]) {
                    __autoreleasing NSString *matchString = nil;
                    DMStringsFileTokenType scannedToken;
                    BOOL stringTokenIsQuoted;
                    
                    if ([scanner scanNextValidStringsTokenIntoString:&matchString tokenType:&scannedToken stringQuoted:&stringTokenIsQuoted]) {
                        switch (scannedToken) {
                            case DMStringsFileTokenKeyString:
                                lastDevFormatString = [[DMFormatString alloc] initWithString:[DMStringsFileScanner unquotedString:matchString if:stringTokenIsQuoted]];
                                if (!lastDevFormatString)
                                    fputs([[NSString stringWithFormat:@"%@: Warning: Invalid key format string %@\n", stringsPath, matchString] UTF8String], stderr), hadParseError = YES;
                                break;
                                
                            case DMStringsFileTokenValueString:
                                lastLocalizedString = [DMStringsFileScanner unquotedString:matchString if:stringTokenIsQuoted];
                                lastLocalizedFormatString = [[DMFormatString alloc] initWithString:[lastLocalizedString stringByTrimmingCharactersInSet:charactersToTrim]];
                                if (!lastLocalizedFormatString)
                                    fputs([[NSString stringWithFormat:@"%@: Warning: Invalid localized format string %@\n", stringsPath, matchString] UTF8String], stderr), hadParseError = YES;
                                break;
                                
                            case DMStringsFileTokenPairTerminator:
                                if (lastDevFormatString && lastLocalizedFormatString) {
                                    if ([scanner scanString:DMNeedsLocalizationMarker intoString:NULL])
                                        break; // Pair wasn't localized
                                    
#ifdef SET_NEEDS_LOCALIZATION_IF_SAME_AS_DEV_STRING
                                    if ([lastLocalizedFormatString isEqual:lastDevFormatString])
                                        break;
#endif
                                    
                                    if ([scanner scanString:DMLocalizationOutOfContextMarker intoString:NULL] || [languageSubfile isEqual:DMOrphanedStringsFilename])
                                        [mapping addLocalization:lastLocalizedFormatString forDevString:lastDevFormatString context:nil];
                                    else
                                        [mapping addLocalization:lastLocalizedFormatString forDevString:lastDevFormatString context:languageSubfile];
                                    [localizationKeys addObject:lastDevFormatString];
                                }
                            default:
                                break;
                        }
                    } else {
                        NSUInteger replayChars = MIN(20u, scanner.scanLocation);
                        fputs([[NSString stringWithFormat:@"%@: Error: Unexpected token at %lu, around: %@\n", stringsPath, scanner.scanLocation, [scanner.string substringWithRange:NSMakeRange(scanner.scanLocation - replayChars, replayChars)]] UTF8String], stderr);
                        hadParseError = YES;
                        break; // If we didn't progress, we have a problem
                    }
                }
            }
            fputs([[NSString stringWithFormat:@"%@: Read %lu localizations\n", lproj, mapping.count] UTF8String], stdout);
        }
        
        if (hadParseError) {
            fputs([[NSString stringWithFormat:@"Parse error building localization tables; aborting.\n"] UTF8String], stderr);
            return EXIT_FAILURE;
        }
        
        /*
         * For each development language strings file, build a new localized file for each target language.
         */
        NSMutableSet *devStringSet = [NSMutableSet new];
        NSMutableDictionary *unlocalizedStringRoughCountByLanguage = [NSMutableDictionary new]; // lang.lproj to NSNumber (NSUInteger), the number of strings for which a translation was not available, with fudging to include strings that are supposedly localized but are the same as the development string
        for (NSString *devStringsComponent in devLanguageStringsFiles) {
            fputs([[NSString stringWithFormat:@"Localizing %@\n", devStringsComponent] UTF8String], stdout);
            // We'll parse this file manually to preserve comments and all that
            NSString *devStringsPath = [[resourcesPath stringByAppendingPathComponent:devLanguageLproj] stringByAppendingPathComponent:devStringsComponent];
            NSString *devStringsContents = [NSString stringWithContentsOfFile:devStringsPath usedEncoding:NULL error:NULL];
            
            for (NSString *lproj in targetLanguageLprojs) {
                DMLocalizationMapping *mapping = translationTables[lproj];
                NSMutableSet *unusedLocalizationKeys = unusedLocalizations[lproj];
                NSUInteger unlocalizedStringRoughCount = [unlocalizedStringRoughCountByLanguage[lproj] unsignedIntegerValue];
                
                NSMutableString *localizedTranscription = [NSMutableString string];
                NSMutableString *savedTranscriptionForDoNotLocalize = localizedTranscription;
                DMStringsFileScanner *scanner = [[DMStringsFileScanner alloc] initWithString:devStringsContents];
                scanner.filePathForErrorLog = devStringsPath;
                
                DMFormatString *lastDevFormatString = nil;
                DMMatchLevel lastFormatStringMatchLevel;
                NSMutableSet *devStringsCountedForLproj = [NSMutableSet new];
                while (![scanner isAtEnd]) {
                    __autoreleasing NSString *matchString = nil;
                    DMStringsFileTokenType scannedToken;
                    BOOL stringTokenIsQuoted;
                    
                    if ([scanner scanNextValidStringsTokenIntoString:&matchString tokenType:&scannedToken stringQuoted:&stringTokenIsQuoted]) {
                        switch (scannedToken) {
                            case DMStringsFileTokenComment:
                            case DMStringsFileTokenWhitespace:
                            case DMStringsFileTokenPairSeparator:
                                [localizedTranscription appendString:matchString];
                                break;
                                
                            case DMStringsFileTokenKeyString:
                                if ([matchString rangeOfString:DMDoNotLocalizeMarker].length > 0)
                                    localizedTranscription = nil; // Short-circuit until we hit the end of this key
                                
                                [devStringSet addObject:matchString];
                                lastDevFormatString = [[DMFormatString alloc] initWithString:[DMStringsFileScanner unquotedString:matchString if:stringTokenIsQuoted]];
                                if (!lastDevFormatString) {
                                    fputs([[NSString stringWithFormat:@"%@: Error: Invalid key format string %@\n", devStringsPath, matchString] UTF8String], stderr);
                                    exit(EXIT_FAILURE);
                                }
                                [localizedTranscription appendString:matchString];
                                break;
                                
                            case DMStringsFileTokenValueString: {
                                NSCAssert(lastDevFormatString, nil);
                                DMFormatString *localizedFormatString = [mapping bestLocalizedFormatStringForDevString:lastDevFormatString forContext:devStringsComponent matchLevel:&lastFormatStringMatchLevel];
                                if (!localizedFormatString) // Use development language
                                    localizedFormatString = [[DMFormatString alloc] initWithString:[DMStringsFileScanner unquotedString:matchString if:stringTokenIsQuoted]];
                                
                                if (lastFormatStringMatchLevel == DMMatchNone && localizedFormatString.probablyNeedsNoLocalization)
                                    lastFormatStringMatchLevel = DMMatchSameContext; // Default strings that are just punctuation, digits, etc. as localized
                                NSString *resultString = [localizedFormatString stringByMatchingFormatString:lastDevFormatString];
                                [unusedLocalizationKeys removeObject:lastDevFormatString];
                                [localizedTranscription appendFormat:@"\"%@\"", resultString];
                                
                                if (lastFormatStringMatchLevel == DMMatchNone && ![devStringsCountedForLproj containsObject:matchString]) {
                                    [devStringsCountedForLproj addObject:matchString];
                                    unlocalizedStringRoughCount++;
                                }
                                break;
                            }
                            case DMStringsFileTokenPairTerminator:
                                [localizedTranscription appendString:matchString];
                                switch (lastFormatStringMatchLevel) {
                                    case DMMatchNone:
                                        [localizedTranscription appendString:DMNeedsLocalizationMarker]; break;
                                    case DMMatchDifferentContext:
                                        [localizedTranscription appendString:DMLocalizationOutOfContextMarker]; break;
                                    case DMMatchSameContext:
                                        break; // No attention needed
                                }
                                localizedTranscription = savedTranscriptionForDoNotLocalize; // Will already be the same unless localization was disabled for a pair
                                lastDevFormatString = nil;
                                break;
                        }
                    } else {
                        NSUInteger replayChars = MIN(20u, scanner.scanLocation);
                        fputs([[NSString stringWithFormat:@"%@: Error: Unexpected token at %lu, around: %@\n", devStringsPath, scanner.scanLocation, [scanner.string substringWithRange:NSMakeRange(scanner.scanLocation - replayChars, replayChars)]] UTF8String], stderr);
                        break; // If we didn't progress, we have a problem
                    }
                }
                
                if (![scanner isAtEnd]) // We didn't process the file completely
                    break; // Break out of processing this strings file for all languages
                
                if ([localizedTranscription characterAtIndex:(localizedTranscription.length - 1)] != '\n')
                    [localizedTranscription appendString:@"\n"];
                
                unlocalizedStringRoughCountByLanguage[lproj] = @(unlocalizedStringRoughCount);
                NSString *localizedStringsPath = [[sourcePath stringByAppendingPathComponent:lproj] stringByAppendingPathComponent:devStringsComponent];
                __autoreleasing NSError *writeError = nil;
                if (![localizedTranscription writeToFile:localizedStringsPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError])
                    fputs([[NSString stringWithFormat:@"%@: Error writing localized strings file: %@", localizedStringsPath, writeError] UTF8String], stderr);
            }
        }
        
        /*
         * Remove strings files no longer present in the development language.
         */
        for (NSString *lproj in targetLanguageLprojs) {
            NSString *langaugeProjPath = [sourcePath stringByAppendingPathComponent:lproj];
            for (NSString *languageSubfile in [fm contentsOfDirectoryAtPath:langaugeProjPath error:NULL]) {
                if ([languageSubfile.pathExtension isEqual:@"strings"] && ![devLanguageStringsFiles containsObject:languageSubfile]) {
                    if (![languageSubfile isEqual:DMOrphanedStringsFilename])
                        fputs([[NSString stringWithFormat:@"Removing source directory strings file %@/%@\n", lproj, languageSubfile] UTF8String], stdout);
                    [fm removeItemAtPath:[langaugeProjPath stringByAppendingPathComponent:languageSubfile] error:NULL];
                }
            }
        }
        
        /*
         * Write orphaned translations
         */
        for (NSString *lproj in targetLanguageLprojs) {
            DMLocalizationMapping *mapping = translationTables[lproj];
            NSMutableString *unusedLocalizedStrings = [NSMutableString stringWithFormat:@"/* Orphaned localized strings for %@ */", lproj];
            NSUInteger orphanedStringCount = 0;
            for (DMFormatString *unusedDevFormatString in unusedLocalizations[lproj]) {
                DMFormatString *localizedFormatString = [mapping bestLocalizedFormatStringForDevString:unusedDevFormatString forContext:nil matchLevel:NULL];
                if (![unusedDevFormatString isEqual:localizedFormatString]) { // Final check: Don't write strings that are the same
                    orphanedStringCount++;
                    [unusedLocalizedStrings appendFormat:@"\n\"%@\" = \"%@\";\n",
                     [unusedDevFormatString stringByMatchingFormatString:unusedDevFormatString],
                     [localizedFormatString stringByMatchingFormatString:unusedDevFormatString]];
                }
            }
            
            if (orphanedStringCount == 0)
                continue;
            NSString *orphanedStringsFilePath = [[sourcePath stringByAppendingPathComponent:lproj] stringByAppendingPathComponent:DMOrphanedStringsFilename];
            [unusedLocalizedStrings writeToFile:orphanedStringsFilePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            fputs([[NSString stringWithFormat:@"Wrote %lu orphaned strings for %@\n", orphanedStringCount, lproj] UTF8String], stdout);
        }
        
        /*
         * Print translation statistics by language
         */
        fputs("\n---- Approximate statistics ----\n", stdout);
        const NSUInteger barWidth = 40;
        for (NSString *lproj in targetLanguageLprojs) {
            NSUInteger roughUnlocalizedCount = [unlocalizedStringRoughCountByLanguage[lproj] unsignedIntegerValue];
            float localizedProportion = 1.0f - ((float)roughUnlocalizedCount / (float)devStringSet.count);
            NSUInteger barCharCount = (NSUInteger)roundf(MAX(MIN(localizedProportion, 1.0f), 0.0f) * barWidth);

            NSString *paddedLproj = [lproj stringByPaddingToLength:15 withString:@" " startingAtIndex:0];
            NSString *bar = [[@"" stringByPaddingToLength:barCharCount withString:@"=" startingAtIndex:0] stringByPaddingToLength:barWidth withString:@" " startingAtIndex:0];
            fputs([[NSString stringWithFormat:@"%@ [%@] %2.f%% localized\n", paddedLproj, bar, localizedProportion * 100.0] UTF8String], stdout);
        }
    }
    return EXIT_SUCCESS;
}


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

@synthesize filePathForErrorLog;

- (id)initWithString:(NSString *)string;
{
    if (!(self = [super initWithString:@""]))
        return nil;
    _scanner = [[NSScanner alloc] initWithString:string];
    self.charactersToBeSkipped = nil;
    _parseState = DMStateExpectingKey;
    return self;
}

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
    NSMutableString *accumulator = [NSMutableString string];
    __autoreleasing NSString *matchString;
    
    if ([_scanner scanString:startComment intoString:&matchString]) {
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

@end


@implementation DMLocalizationMapping {
    NSString *_name;
    NSMutableDictionary *_allMappings;
    NSMutableDictionary *_mappingsByTableName;
}

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

@implementation DMFormatString

@synthesize usesExplicitFormatSpecifierPositions = _usesExplicitFormatSpecifierPositions;
@synthesize probablyNeedsNoLocalization = _probablyNeedsNoLocalization;
@synthesize components = _components; // Array of NSString and DMFormatSpecifier objects interleaved
@synthesize formatSpecifiersByPosition = _formatSpecifiersByPosition;

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
            if ([component stringByTrimmingCharactersInSet:[[NSCharacterSet letterCharacterSet] invertedSet]].length > 0) {
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

- (id)copyWithZone:(NSZone *)zone;
{ return self; }

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

@end


@implementation DMFormatSpecifier

@synthesize specifierType = _specifierType;
@synthesize position = _position;
@synthesize positionWasExplicit = _positionWasExplicit;
@synthesize specifierString = _specifierString;

#define TERMINATING_CHARSET  @"dDiuUxXoOfeEgGcCsSpaAF@"

+ (NSCharacterSet *)terminatingCharacterSet;
{
    static dispatch_once_t onceToken;
    static NSCharacterSet *terminatingCharacterSet;
    dispatch_once(&onceToken, ^{
        terminatingCharacterSet = [NSCharacterSet characterSetWithCharactersInString:TERMINATING_CHARSET];
    });
    return terminatingCharacterSet;
}

- (id)initWithString:(NSString *)potentialSpecifierString positionIfImplicit:(NSInteger)implicitPosition;
{
    static dispatch_once_t onceToken;
    static NSRegularExpression *formatStringSpecifierRegExp, *displayPatternSpecifierRegExp, *ruleEditorSpecifierRegExp;
    dispatch_once(&onceToken, ^{
        /* Encodings:
         *   Literal percent: %% (NOT handled here; handed by scanner)
         *   Format string: %@  %.3f  %d  %ld  %3d  %3$@
         *   Binding display pattern: %{value1}@  %{value2}@
         *   Rule editor: %[a,b,c]@  %1$[list,that]@
         */
#define POSITION_RE  @"(\\d+\\$)"
#define FS_FLAG_CHARSET  @"-'+ #0"
#define LENGTH_MODIFIER_RE @"[hl]?[hljztLq]?" // Only CFString docs has "q"
        // Indirect field widths and precisions are not supported. (They introduce a dependency on another position.)
        formatStringSpecifierRegExp = [NSRegularExpression regularExpressionWithPattern:
                                       @"%"POSITION_RE"?["FS_FLAG_CHARSET"]?\\d*\\.?\\d*"LENGTH_MODIFIER_RE"["TERMINATING_CHARSET"]" options:0 error:NULL];
        displayPatternSpecifierRegExp = [NSRegularExpression regularExpressionWithPattern:@"%\\{value(\\d+)\\}@" options:0 error:NULL];
        ruleEditorSpecifierRegExp = [NSRegularExpression regularExpressionWithPattern:@"%"POSITION_RE"?\\[[^]]*\\]@" options:0 error:NULL];
    });
    
    if (!(self = [super init]))
        return nil;
    if (potentialSpecifierString.length < 2)
        return nil;
    if ([potentialSpecifierString isEqual:@"%%"])
        return nil; // %% is a literal percent, not a specifier
    
    NSRange fullRange = NSMakeRange(0, potentialSpecifierString.length);
    NSTextCheckingResult *formatStringMatch = nil, *displayPatternMatch = nil, *ruleEditorMatch = nil;
    formatStringMatch = [formatStringSpecifierRegExp firstMatchInString:potentialSpecifierString options:NSMatchingAnchored range:fullRange];
    if (formatStringMatch) {
        _specifierString = [potentialSpecifierString copy];
        _specifierType = DMFormatSpecifierFormatStringType;
        if ([formatStringMatch rangeAtIndex:1].length > 1)
            _positionWasExplicit = YES, _position = [[potentialSpecifierString substringWithRange:[formatStringMatch rangeAtIndex:1]] integerValue];
        else
            _position = implicitPosition;
        return self;
    }
    displayPatternMatch = [displayPatternSpecifierRegExp firstMatchInString:potentialSpecifierString options:NSMatchingAnchored range:fullRange];
    if (displayPatternMatch) {
        _specifierString = [potentialSpecifierString copy];
        _specifierType = DMFormatSpecifierDisplayPatternType;
        _positionWasExplicit = YES, _position = [[potentialSpecifierString substringWithRange:[displayPatternMatch rangeAtIndex:1]] integerValue];
        return self;
    }
    ruleEditorMatch = [ruleEditorSpecifierRegExp firstMatchInString:potentialSpecifierString options:NSMatchingAnchored range:fullRange];
    if (ruleEditorMatch) {
        _specifierString = [potentialSpecifierString copy];
        _specifierType = DMFormatSpecifierRuleEditorType;
        if ([ruleEditorMatch rangeAtIndex:1].length > 1)
            _positionWasExplicit = YES, _position = [[potentialSpecifierString substringWithRange:[ruleEditorMatch rangeAtIndex:1]] integerValue];
        else
            _position = implicitPosition;
        return self;
    }
    return nil;
}

- (NSString *)stringWithExplicitPosition;
{
    if (_positionWasExplicit)
        return self.specifierString;
    else
        return [NSString stringWithFormat:@"%%%ld$%@", self.position, [self.specifierString substringFromIndex:1]];
}

- (NSUInteger)hash;
{ return _position; }

- (BOOL)isEqual:(id)other;
{
    if (![other isKindOfClass:[DMFormatSpecifier class]])
        return NO;
    DMFormatSpecifier *otherSpecifier = other;
    // Rule editor specifiers are equal only to themselves
    if (self.specifierType == DMFormatSpecifierRuleEditorType && otherSpecifier.specifierType == DMFormatSpecifierRuleEditorType)
        return [self.specifierString isEqual:otherSpecifier.specifierString];
    else if (self.specifierType == DMFormatSpecifierRuleEditorType || otherSpecifier.specifierType == DMFormatSpecifierRuleEditorType)
        return NO;
    return self.position == otherSpecifier.position;
}

- (NSString *)description;
{ return _specifierString; }

@end
