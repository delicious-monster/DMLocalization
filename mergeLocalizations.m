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
static NSString *const DMNeedsLocalizationMarker = @" /*!!! Needs translation, delete this comment when translated !!!*/";
static NSString *const DMLocalizationOutOfContextMarker = @" /*!!! Translation found in different context, delete this comment if ok !!!*/";
static NSString *const templateLanguageLproj = @"Example.lproj", *const devLanguageLproj = @"en.lproj", *const baseLanguageLproj = @"Base.lproj";

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSFileManager *const fileManager = [NSFileManager defaultManager];
        NSDictionary *const environmentDictionary = [NSProcessInfo processInfo].environment;
        
        // Set paths
        NSString *sourcePath = environmentDictionary[@"SRCROOT"];
        if (!sourcePath)
            sourcePath = [@"~/Source/UberLibrary/Library" stringByExpandingTildeInPath];
        if (![fileManager fileExistsAtPath:sourcePath]) {
            fputs([[NSString stringWithFormat:@"Error: source directory must exist (%@)\n", sourcePath] UTF8String], stderr);
            exit(EXIT_FAILURE);
        }
        
        //
        // STEP 1: Parse Example.lproj
        // Build index of strings files in the development language, and the target translation languages
        //
        NSMutableSet *const devLanguageStringsFiles = [NSMutableSet set]; {
            for (NSString *languageSubfile in [fileManager contentsOfDirectoryAtPath:[sourcePath stringByAppendingPathComponent:templateLanguageLproj] error:NULL])
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


        //
        // STEP 2: Build corpus
        // First, for each language, build a DMLocalizationMapping of each key-value pair, also storing the name of the strings file in which each pair was found.
        //
        fputs([@"Building translation tables\n" UTF8String], stdout);
        BOOL hadParseError = NO;
        NSMutableDictionary *const translationTables = [NSMutableDictionary new]; // lang.lproj to DMLocalizationMapping
        NSMutableDictionary *const unusedLocalizations = [NSMutableDictionary new]; // lang.lproj to NSMutableSet of DMFormatString

        for (NSString *lproj in targetLanguageLprojs) {
            DMLocalizationMapping *const mapping = [[DMLocalizationMapping alloc] initWithName:lproj];
            translationTables[lproj] = mapping;
            
            NSMutableSet *const localizationKeys = [NSMutableSet set];
            unusedLocalizations[lproj] = localizationKeys;
            
            NSString *const langaugeProjPath = [sourcePath stringByAppendingPathComponent:lproj];
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
                
                NSError *regularExpressionError = nil;
                NSRegularExpression *const xibCommentRegularExpression = [NSRegularExpression regularExpressionWithPattern:@"^/\\* Class = \"\\S+\"; (\\S+) = \"(.*)\"; ObjectID = \"(\\d+)\"; \\*/$" options:NSRegularExpressionAnchorsMatchLines error:&regularExpressionError];
                if (!xibCommentRegularExpression) {
                    fputs([[NSString stringWithFormat:@"Regular expression error: %@.\n", regularExpressionError] UTF8String], stderr);
                    exit(EXIT_FAILURE);
                }

                DMStringsFileScanner *const scanner = [[DMStringsFileScanner alloc] initWithString:stringsContents];
                scanner.filePathForErrorLog = stringsPath;


                DMFormatString *keyFormatString = nil, *xibKeyFormatString = nil, *valueFormatString = nil;
                while (![scanner isAtEnd]) {
                    __autoreleasing NSString *matchString = nil;
                    DMStringsFileTokenType scannedToken;
                    BOOL stringTokenIsQuoted;
                    
                    if (![scanner scanNextValidStringsTokenIntoString:&matchString tokenType:&scannedToken stringQuoted:&stringTokenIsQuoted]) {
                        const NSUInteger replayChars = MIN(20u, scanner.scanLocation);
                        fputs([[NSString stringWithFormat:@"%@: Error: Unexpected token at %lu, around: %@\n", stringsPath, scanner.scanLocation, [scanner.string substringWithRange:NSMakeRange(scanner.scanLocation - replayChars, replayChars)]] UTF8String], stderr);
                        hadParseError = YES;
                        break; // If we didn't progress, we have a problem
                    }

                    switch (scannedToken) {
                        case DMStringsFileTokenComment: {
                            // If we're parsing a XIB, we want to use the comment line before the “"foo" = "le foo";” line to set up our keys, for two reasons: (1) we used to use the English strings as the key, but 10.8 introduced their own automatic XIB localization which use the style “222.title = "foo";”, and we have to accept both new and old-style strings files at least for the next while, and (2) we want to cross-index each translation, both using the new-style XIB key and the old English word, so if the same key appears elsewhere but is missing a translation  we can auto-fill in this one (this will happen every time an object in our XIB has its OID change, so it'll be somewhat common).

                            // example of a XIB comment: /* Class = "NSMenuItem"; title = "Fi\"le"; ObjectID = "83"; */
                            // next line would be: "83.title" = "Fi\"le";
                            if ([matchString hasPrefix:@"/* Class ="] && [matchString hasSuffix:@"*/"]) {
                                NSTextCheckingResult *const result = [xibCommentRegularExpression firstMatchInString:matchString options:0 range:(NSRange){0, matchString.length}];
                                if (result.numberOfRanges == 4) {
                                    keyFormatString = [[DMFormatString alloc] initWithString:[matchString substringWithRange:[result rangeAtIndex:2]]]; // eg: "foo"
                                    NSString *const xibPropertyKeyString = [matchString substringWithRange:[result rangeAtIndex:1]]; // eg: "title"
                                    NSString *const objectIDStringPrefix = [[matchString substringWithRange:[result rangeAtIndex:3]] stringByAppendingString:@"."]; // eg: "979"
                                    xibKeyFormatString = [[DMFormatString alloc] initWithString:[([xibPropertyKeyString hasPrefix:objectIDStringPrefix] ? @"" : objectIDStringPrefix) stringByAppendingString:xibPropertyKeyString]]; // eg: "22.title" — NOTE: handle bullshit like: /* Class = "NSSegmentedCell"; 979.ibShadowedLabels[0] = "Address Book"; ObjectID = "979"; */
                                }
                            }
                            break;
                        }

                        case DMStringsFileTokenKeyString: {
                            DMFormatString *const lineKeyFormatString = [[DMFormatString alloc] initWithString:[DMStringsFileScanner unquotedString:matchString if:stringTokenIsQuoted]];
                            if (!lineKeyFormatString) {
                                fputs([[NSString stringWithFormat:@"%@: Warning: Invalid key format string %@\n", stringsPath, matchString] UTF8String], stderr);
                                hadParseError = YES;
                            }

                            if (!keyFormatString)
                                keyFormatString = lineKeyFormatString;

                            else if (!xibKeyFormatString) {
                                fputs([[NSString stringWithFormat:@"%@: Warning: key format string “%@” has previous value(?) “%@”\n", stringsPath, lineKeyFormatString, keyFormatString] UTF8String], stderr);
                                hadParseError = YES;

                            } else { // just make sure this key matches one of the keys we read from the XIB, earlier
                                if (![lineKeyFormatString isEqual:keyFormatString] && ![lineKeyFormatString isEqual:xibKeyFormatString]) {
                                    fputs([[NSString stringWithFormat:@"%@: Warning: key format string “%@” doesn't match keys in XIB comment “%@” “%@”\n", stringsPath, lineKeyFormatString, keyFormatString, xibKeyFormatString] UTF8String], stderr);
                                    hadParseError = YES;
                                }
                            }
                            break;
                        }

                        case DMStringsFileTokenValueString: {
                            // NSString *const valueString = [DMStringsFileScanner unquotedString:matchString if:stringTokenIsQuoted];
                            // lastLocalizedString = [lastLocalizedString stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\u261b\u261e"]];  // Clean up legacy translation markers ("hand" characters)
                            valueFormatString = [[DMFormatString alloc] initWithString:[DMStringsFileScanner unquotedString:matchString if:stringTokenIsQuoted]];
                            if (!valueFormatString)
                                fputs([[NSString stringWithFormat:@"%@: Warning: Invalid localized format string %@\n", stringsPath, matchString] UTF8String], stderr), hadParseError = YES;
                            break;
                        }

                        case DMStringsFileTokenPairTerminator: {
                            if (keyFormatString && valueFormatString
#ifdef SET_NEEDS_LOCALIZATION_IF_SAME_AS_DEV_STRING
                                && ![valueFormatString isEqual:keyFormatString])
#endif
                                && ![scanner scanString:DMNeedsLocalizationMarker intoString:NULL] // Pair wasn't localized
                                && ![valueFormatString.description rangeOfString:@"??"].length) { // Old localizations may still have some of these knocking around, clean them out whenever we can. eg: /* Class = "NSTextFieldCell"; title = "???? synopsis body"; ObjectID = "222"; */


                                NSString *const scanContextString = ([scanner scanString:DMLocalizationOutOfContextMarker intoString:NULL] || [languageSubfile isEqual:DMOrphanedStringsFilename]) ? nil : languageSubfile;

                                [mapping addLocalization:valueFormatString forDevString:keyFormatString context:scanContextString];
                                if (xibKeyFormatString) {
                                    [mapping addLocalization:valueFormatString forDevString:xibKeyFormatString context:scanContextString];
                                    //fprintf(stderr, "“%s”,“%s”->“%s” \n", keyFormatString.description.UTF8String, xibKeyFormatString.description.UTF8String, valueFormatString.description.UTF8String);
                                }

                                [localizationKeys addObject:xibKeyFormatString ? : keyFormatString]; // prefer XIB key since that's the one we'll mark as being used, below
                            }
                            keyFormatString = xibKeyFormatString = valueFormatString = nil; // gotta clear these out WHENEVER we see the end of any key/value pair or we throw bogus errors like: "key format string x has previous value(?) y"
                        }
                        default:
                            break;
                    }
                }
            }
            fputs([[NSString stringWithFormat:@"%@: Read %lu localizations\n", lproj, mapping.count] UTF8String], stdout);
        }
        
        if (hadParseError) {
            fputs([[NSString stringWithFormat:@"Parse error building localization tables; aborting.\n"] UTF8String], stderr);
            return EXIT_FAILURE;
        }

        //
        // STEP 3: localize
        // For each development language strings file, build a new localized file for each target language.
        //
        NSMutableSet *const templateStringSet = [NSMutableSet new];
        NSMutableDictionary *const unlocalizedStringRoughCountByLanguage = [NSMutableDictionary new]; // lang.lproj to NSNumber (NSUInteger), the number of strings for which a translation was not available, with fudging to include strings that are supposedly localized but are the same as the development string
        for (NSString *devStringsComponent in devLanguageStringsFiles) {
            fputs([[NSString stringWithFormat:@"Localizing %@\n", devStringsComponent] UTF8String], stdout);
            
            NSString *const templateStringsPath = [[sourcePath stringByAppendingPathComponent:templateLanguageLproj] stringByAppendingPathComponent:devStringsComponent];
            NSString *const templateStringsContents = [NSString stringWithContentsOfFile:templateStringsPath usedEncoding:NULL error:NULL];
            
            for (NSString *lproj in targetLanguageLprojs) {
                DMLocalizationMapping *const mapping = translationTables[lproj];
                NSMutableSet *const unusedLocalizationKeys = unusedLocalizations[lproj];
                NSUInteger unlocalizedStringRoughCount = [unlocalizedStringRoughCountByLanguage[lproj] unsignedIntegerValue];
                
                NSMutableString *mutableLocalizedStringsInTargetLanguageString = [NSMutableString string];
                DMStringsFileScanner *const templateStringsScanner = [[DMStringsFileScanner alloc] initWithString:templateStringsContents];
                templateStringsScanner.filePathForErrorLog = templateStringsPath;
                
                DMFormatString *keyFormatString = nil;
                BOOL keyAppearsToBeFromXIB = NO;
                DMMatchLevel lastFormatStringMatchLevel;
                NSMutableSet *const devStringsCountedForLproj = [NSMutableSet new];
                while (!templateStringsScanner.isAtEnd) {
                    __autoreleasing NSString *matchString = nil;
                    DMStringsFileTokenType scannedToken;
                    BOOL stringTokenIsQuoted;
                    
                    if ([templateStringsScanner scanNextValidStringsTokenIntoString:&matchString tokenType:&scannedToken stringQuoted:&stringTokenIsQuoted]) {
                        switch (scannedToken) {
                            case DMStringsFileTokenComment:
                                keyAppearsToBeFromXIB = [matchString hasPrefix:@"/* Class ="] && [matchString hasSuffix:@"*/"];
                                    // FALL THROUGH
                            case DMStringsFileTokenWhitespace:
                            case DMStringsFileTokenPairSeparator:
                                [mutableLocalizedStringsInTargetLanguageString appendString:matchString];
                                break;
                                
                            case DMStringsFileTokenKeyString:
                                [templateStringSet addObject:matchString];

                                keyFormatString = [[DMFormatString alloc] initWithString:[DMStringsFileScanner unquotedString:matchString if:stringTokenIsQuoted]];
                                if (!keyFormatString) {
                                    fputs([[NSString stringWithFormat:@"%@: Error: Invalid key format string %@\n", templateStringsPath, matchString] UTF8String], stderr);
                                    exit(EXIT_FAILURE);
                                }
                                [mutableLocalizedStringsInTargetLanguageString appendString:matchString];
                                break;
                                
                            case DMStringsFileTokenValueString: {
                                NSCAssert(keyFormatString, nil);

                                DMFormatString *const baseLanguageValueFormatString = [[DMFormatString alloc] initWithString:[DMStringsFileScanner unquotedString:matchString if:stringTokenIsQuoted]];

                                DMFormatString *valueFormatString = [mapping bestLocalizedFormatStringForDevString:keyFormatString forContext:devStringsComponent matchLevel:&lastFormatStringMatchLevel];
                                if (keyAppearsToBeFromXIB && lastFormatStringMatchLevel != DMMatchSameContext) // Look up using base's right-hand-side, so we find from actual English word, not opaque key, eg: "83.title" = "File";
                                        valueFormatString = [mapping bestLocalizedFormatStringForDevString:baseLanguageValueFormatString forContext:devStringsComponent matchLevel:&lastFormatStringMatchLevel];
                                if (!valueFormatString) // Use development language
                                    valueFormatString = baseLanguageValueFormatString;
                                
                                if (lastFormatStringMatchLevel == DMMatchNone && valueFormatString.probablyNeedsNoLocalization)
                                    lastFormatStringMatchLevel = DMMatchSameContext; // Default strings that are just punctuation, digits, etc. as localized
                                NSString *const resultString = [valueFormatString stringByMatchingFormatString:keyFormatString];
                                [unusedLocalizationKeys removeObject:keyFormatString];
                                [mutableLocalizedStringsInTargetLanguageString appendFormat:@"\"%@\"", resultString];
                                
                                if (lastFormatStringMatchLevel == DMMatchNone && ![devStringsCountedForLproj containsObject:matchString]) {
                                    [devStringsCountedForLproj addObject:matchString];
                                    unlocalizedStringRoughCount++;
                                }
                                break;
                            }
                            case DMStringsFileTokenPairTerminator:
                                [mutableLocalizedStringsInTargetLanguageString appendString:matchString];
                                switch (lastFormatStringMatchLevel) {
                                    case DMMatchNone:
                                        [mutableLocalizedStringsInTargetLanguageString appendString:DMNeedsLocalizationMarker]; break;
                                    case DMMatchDifferentContext:
                                        [mutableLocalizedStringsInTargetLanguageString appendString:DMLocalizationOutOfContextMarker]; break;
                                    case DMMatchSameContext:
                                        break; // No attention needed
                                }

                                keyFormatString = nil;
                                break;
                        }
                        
                    } else {
                        const NSUInteger replayChars = MIN(20u, templateStringsScanner.scanLocation);
                        fputs([[NSString stringWithFormat:@"%@: Error: Unexpected token at %lu, around: %@\n", templateStringsPath, templateStringsScanner.scanLocation, [templateStringsScanner.string substringWithRange:NSMakeRange(templateStringsScanner.scanLocation - replayChars, replayChars)]] UTF8String], stderr);
                        break; // If we didn't progress, we have a problem
                    }
                }
                
                if (![templateStringsScanner isAtEnd]) // We didn't process the file completely
                    break; // Break out of processing this strings file for all languages
                
                if ([mutableLocalizedStringsInTargetLanguageString characterAtIndex:(mutableLocalizedStringsInTargetLanguageString.length - 1)] != '\n')
                    [mutableLocalizedStringsInTargetLanguageString appendString:@"\n"];
                
                unlocalizedStringRoughCountByLanguage[lproj] = @(unlocalizedStringRoughCount);
                NSString *localizedStringsPath = [[sourcePath stringByAppendingPathComponent:lproj] stringByAppendingPathComponent:devStringsComponent];
                __autoreleasing NSError *writeError = nil;
                if (![mutableLocalizedStringsInTargetLanguageString writeToFile:localizedStringsPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError])
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
