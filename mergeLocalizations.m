//
//  main.m
//  mergeLocalizations
//
//  Created by Jonathon Mah on 2011-07-25.
//  Copyright 2011 Delicious Monster Software. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "DMFormatSpecifier.h"
#import "DMFormatString.h"
#import "DMLocalizationMapping.h"
#import "DMStringsFileScanner.h"


//#define SET_NEEDS_LOCALIZATION_IF_SAME_AS_DEV_STRING
static NSString *const DMOrphanedStringsFilename = @"_unused do not localize.strings";
static NSString *const DMDoNotLocalizeMarker = @"??";
static NSString *const DMNeedsLocalizationMarker = @" /*!!! Needs translation, delete this comment when translated !!!*/";
static NSString *const DMLocalizationOutOfContextMarker = @" /*!!! Translation found in different context, delete this comment if ok !!!*/";
static NSString *const templateLanguageLproj = @"Example.lproj", *const devLanguageLproj = @"en.lproj", *const baseLanguageLproj = @"Base.lproj";

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSFileManager *const fileManager = [NSFileManager defaultManager];
        NSDictionary *const environmentDictionary = [NSProcessInfo processInfo].environment;
        
        // Set paths
        NSString *resourcesPath, *sourcePath;
        if (environmentDictionary[@"TARGET_BUILD_DIR"]) {
            resourcesPath = [environmentDictionary[@"TARGET_BUILD_DIR"] stringByAppendingPathComponent:environmentDictionary[@"UNLOCALIZED_RESOURCES_FOLDER_PATH"]];
            sourcePath = environmentDictionary[@"SRCROOT"];
        } else {
            resourcesPath = [@"~/Library/Developer/Xcode/DerivedData/UberLibrary-btotfnkzlnxlxgahpezzqtypnhpm/Build/Products/Debug/Delicious Library 3.app/Contents/Resources" stringByExpandingTildeInPath];
            sourcePath = [@"~/Source/UberLibrary/Library" stringByExpandingTildeInPath];
        }
        if (![fileManager fileExistsAtPath:resourcesPath] || ![fileManager fileExistsAtPath:sourcePath]) {
            fputs([[NSString stringWithFormat:@"Error: Resources and source directories must exist (%@ and %@)\n", resourcesPath, sourcePath] UTF8String], stderr);
            exit(EXIT_FAILURE);
        }
        
        
        // Build index of strings files in the development language, and the target translation languages
        NSMutableSet *const devLanguageStringsFiles = [NSMutableSet set]; {
            for (NSString *languageSubfile in [fileManager contentsOfDirectoryAtPath:[resourcesPath stringByAppendingPathComponent:templateLanguageLproj] error:NULL])
                if ([languageSubfile.pathExtension isEqualToString:@"strings"])
                    [devLanguageStringsFiles addObject:languageSubfile];
        }
        
        NSMutableSet *const targetLanguageLprojs = [NSMutableSet set]; {
            __autoreleasing NSError *traverseError = nil;
            NSArray *const sourceContents = [fileManager contentsOfDirectoryAtPath:sourcePath error:&traverseError];
            if (!sourceContents) {
                fputs([[NSString stringWithFormat:@"Error: Unable to list contents of directory at %@: %@\n", sourcePath, traverseError] UTF8String], stderr);
                exit(EXIT_FAILURE);
            }
            for (NSString *sourcePathComponent in sourceContents)
                if ([sourcePathComponent.pathExtension isEqualToString:@"lproj"] && ![sourcePathComponent isEqualToString:devLanguageLproj] && ![sourcePathComponent isEqualToString:baseLanguageLproj] && ![sourcePathComponent isEqualToString:templateLanguageLproj])
                    [targetLanguageLprojs addObject:sourcePathComponent];
        }
        
        /*
         * First, for each language, build a DMLocalizationMapping of each key-value pair,
         * also storing the name of the strings file in which each pair was found.
         */
        fputs([@"Building translation tables\n" UTF8String], stdout);
        BOOL hadParseError = NO;
        NSMutableDictionary *const translationTables = [NSMutableDictionary new]; // lang.lproj to DMLocalizationMapping
        NSMutableDictionary *const unusedLocalizations = [NSMutableDictionary new]; // lang.lproj to NSMutableSet of DMFormatString
        
        for (NSString *lproj in targetLanguageLprojs) {
            DMLocalizationMapping *mapping = [[DMLocalizationMapping alloc] initWithName:lproj];
            translationTables[lproj] = mapping;
            NSMutableSet *localizationKeys = [NSMutableSet set];
            unusedLocalizations[lproj] = localizationKeys;
            
            NSString *langaugeProjPath = [sourcePath stringByAppendingPathComponent:lproj];
            for (NSString *languageSubfile in [fileManager contentsOfDirectoryAtPath:langaugeProjPath error:NULL]) {
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
                                // lastLocalizedString = [lastLocalizedString stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\u261b\u261e"]];  // Clean up legacy translation markers ("hand" characters)
                                lastLocalizedFormatString = [[DMFormatString alloc] initWithString:lastLocalizedString];
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
        NSMutableSet *const templateStringSet = [NSMutableSet new];
        NSMutableDictionary *const unlocalizedStringRoughCountByLanguage = [NSMutableDictionary new]; // lang.lproj to NSNumber (NSUInteger), the number of strings for which a translation was not available, with fudging to include strings that are supposedly localized but are the same as the development string
        for (NSString *devStringsComponent in devLanguageStringsFiles) {
            fputs([[NSString stringWithFormat:@"Localizing %@\n", devStringsComponent] UTF8String], stdout);
            
            // We'll parse this file manually to preserve comments and all that
            NSString *const templateStringsPath = [[resourcesPath stringByAppendingPathComponent:templateLanguageLproj] stringByAppendingPathComponent:devStringsComponent];
            NSString *const templateStringsContents = [NSString stringWithContentsOfFile:templateStringsPath usedEncoding:NULL error:NULL];
            
            for (NSString *lproj in targetLanguageLprojs) {
                DMLocalizationMapping *mapping = translationTables[lproj];
                NSMutableSet *unusedLocalizationKeys = unusedLocalizations[lproj];
                NSUInteger unlocalizedStringRoughCount = [unlocalizedStringRoughCountByLanguage[lproj] unsignedIntegerValue];
                
                NSMutableString *localizedTranscription = [NSMutableString string];
                NSMutableString *savedTranscriptionForDoNotLocalize = localizedTranscription;
                DMStringsFileScanner *scanner = [[DMStringsFileScanner alloc] initWithString:templateStringsContents];
                scanner.filePathForErrorLog = templateStringsPath;
                
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
                                
                                [templateStringSet addObject:matchString];
                                lastDevFormatString = [[DMFormatString alloc] initWithString:[DMStringsFileScanner unquotedString:matchString if:stringTokenIsQuoted]];
                                if (!lastDevFormatString) {
                                    fputs([[NSString stringWithFormat:@"%@: Error: Invalid key format string %@\n", templateStringsPath, matchString] UTF8String], stderr);
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
                        fputs([[NSString stringWithFormat:@"%@: Error: Unexpected token at %lu, around: %@\n", templateStringsPath, scanner.scanLocation, [scanner.string substringWithRange:NSMakeRange(scanner.scanLocation - replayChars, replayChars)]] UTF8String], stderr);
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
            for (NSString *languageSubfile in [fileManager contentsOfDirectoryAtPath:langaugeProjPath error:NULL]) {
                if ([languageSubfile.pathExtension isEqual:@"strings"] && ![devLanguageStringsFiles containsObject:languageSubfile]) {
                    if (![languageSubfile isEqual:DMOrphanedStringsFilename])
                        fputs([[NSString stringWithFormat:@"Removing source directory strings file %@/%@\n", lproj, languageSubfile] UTF8String], stdout);
                    [fileManager removeItemAtPath:[langaugeProjPath stringByAppendingPathComponent:languageSubfile] error:NULL];
                }
            }
        }
        
        /*
         * Write orphaned translations
         */
        for (NSString *lproj in targetLanguageLprojs) {
            DMLocalizationMapping *mapping = translationTables[lproj];
            NSMutableString *unusedLocalizedStrings = [NSMutableString stringWithFormat:@"/* These strings aren't used any more, no need to localize them [language %@] */", lproj];
            NSUInteger orphanedStringCount = 0;
            for (DMFormatString *unusedDevFormatString in [unusedLocalizations[lproj] sortedArrayUsingDescriptors:@[[NSSortDescriptor sortDescriptorWithKey:@"description" ascending:YES]]]) {
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
            float localizedProportion = 1.0f - ((float)roughUnlocalizedCount / (float)templateStringSet.count);
            NSUInteger barCharCount = (NSUInteger)roundf(MAX(MIN(localizedProportion, 1.0f), 0.0f) * barWidth);

            NSString *paddedLproj = [lproj stringByPaddingToLength:15 withString:@" " startingAtIndex:0];
            NSString *bar = [[@"" stringByPaddingToLength:barCharCount withString:@"=" startingAtIndex:0] stringByPaddingToLength:barWidth withString:@" " startingAtIndex:0];
            fputs([[NSString stringWithFormat:@"%@ [%@] %2.f%% localized\n", paddedLproj, bar, localizedProportion * 100.0] UTF8String], stdout);
        }
    }
    return EXIT_SUCCESS;
}
