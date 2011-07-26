//
//  main.m
//  mergeLocalizations
//
//  Created by Jonathon Mah on 2011-07-25.
//  Copyright 2011 Delicious Monster Software. All rights reserved.
//

#import <Foundation/Foundation.h>


@interface DMFormatString : NSObject <NSCopying>
- (id)initWithString:(NSString *)string;
- (NSString *)stringByMatchingFormatString:(DMFormatString *)targetFormatString;
@property (readonly, nonatomic) BOOL formatSpecifierPositionsAreMonotonic;
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
- (void)addLocalization:(DMFormatString *)localizedFormatString forDevString:(DMFormatString *)devFormatString context:(NSString *)tableName;
- (DMFormatString *)bestLocalizedFormatStringForDevString:(DMFormatString *)devFormatString forContext:(NSString *)tableName matchLevel:(out DMMatchLevel *)outMatchLevel;
@end


int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *env = [[NSProcessInfo processInfo] environment];
        
        // Set paths
        NSString *resourcesPath, *sourcePath, *devLanguageLproj;
        if ([env objectForKey:@"TARGET_BUILD_DIR"]) {
            resourcesPath = [[env objectForKey:@"TARGET_BUILD_DIR"] stringByAppendingPathComponent:[env objectForKey:@"UNLOCALIZED_RESOURCES_FOLDER_PATH"]];
            sourcePath = [env objectForKey:@"SRCROOT"];
            devLanguageLproj = [[env objectForKey:@"DEVELOPMENT_LANGUAGE"] stringByAppendingPathExtension:@"lproj"];
        } else {
            resourcesPath = [@"~/Library/Developer/Xcode/DerivedData/UberLibrary-djzgxxrdrlqezxgaansiwhdraxmn/Build/Products/Debug/Delicious Library 3.app/Contents/Resources" stringByExpandingTildeInPath];
            sourcePath = [@"~/Documents/Streams/Delicious Monster/UberLibrary/Library" stringByExpandingTildeInPath];
            devLanguageLproj = @"English.lproj";
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
        NSMutableDictionary *translationTables = [NSMutableDictionary new]; // lang.lproj to DMLocalizationMapping
        
        for (NSString *lproj in targetLanguageLprojs) {
            DMLocalizationMapping *mapping = [[DMLocalizationMapping alloc] initWithName:lproj];
            [translationTables setObject:mapping forKey:lproj];
            
            NSString *langaugeProjPath = [sourcePath stringByAppendingPathComponent:lproj];
            for (NSString *languageSubfile in [fm contentsOfDirectoryAtPath:langaugeProjPath error:NULL]) {
                if (![languageSubfile.pathExtension isEqual:@"strings"])
                    continue;
                NSString *stringsPath = [langaugeProjPath stringByAppendingPathComponent:languageSubfile];
                NSDictionary *localizedStrings = [NSDictionary dictionaryWithContentsOfFile:stringsPath];
                if (!localizedStrings) {
                    fputs([[NSString stringWithFormat:@"%@: Error: Unable to read strings file\n", stringsPath] UTF8String], stderr);
                    continue;
                }
                
                [localizedStrings enumerateKeysAndObjectsUsingBlock:^(NSString *devString, NSString *localizedString, BOOL *stop) {
                    DMFormatString *devFormatString = [[DMFormatString alloc] initWithString:devString];
                    if (!devFormatString) {
                        fputs([[NSString stringWithFormat:@"%@: Warning: Invalid key format string %@\n", stringsPath, devString] UTF8String], stderr);
                        return;
                    }
                    DMFormatString *localizedFormatString = [[DMFormatString alloc] initWithString:localizedString];
                    if (!localizedFormatString) {
                        fputs([[NSString stringWithFormat:@"%@: Warning: Invalid localized format string %@\n", stringsPath, localizedString] UTF8String], stderr);
                        return;
                    }
                    [mapping addLocalization:localizedFormatString forDevString:devFormatString context:languageSubfile];
                }];
            }
            fputs([[NSString stringWithFormat:@"%@: Read %lu localizations\n", lproj, mapping.count] UTF8String], stdout);
        }
        
        
        /*
         * For each development language strings file, build a new localized file for each target language.
         */
        typedef enum {
            DMStateExpectingKey,
            DMStateExpectingEquals,
            DMStateExpectingValue,
            DMStateExpectingSemicolon,
        } DMParseState;
        
        NSString *startComment = @"/*", *endComment = @"*/";
        NSCharacterSet *maybeEndQuotedStringSet = [NSCharacterSet characterSetWithCharactersInString:@"\\\""]; // Double-quote or backslash
        
        for (NSString *devStringsComponent in devLanguageStringsFiles) {
            fputs([[NSString stringWithFormat:@"Localizing %@\n", devStringsComponent] UTF8String], stdout);
            // We'll parse this file manually to preserve comments and all that
            NSString *devStringsPath = [[resourcesPath stringByAppendingPathComponent:devLanguageLproj] stringByAppendingPathComponent:devStringsComponent];
            NSString *devStringsContents = [NSString stringWithContentsOfFile:devStringsPath usedEncoding:NULL error:NULL];
            
            for (NSString *lproj in targetLanguageLprojs) {
                DMLocalizationMapping *mapping = [translationTables objectForKey:lproj];
                NSMutableString *localizedTranscription = [NSMutableString string];
                NSScanner *scanner = [NSScanner scannerWithString:devStringsContents];
                scanner.charactersToBeSkipped = nil;
                
                DMParseState parseState = DMStateExpectingKey;
                DMFormatString *lastDevFormatString = nil;
                while (![scanner isAtEnd]) {
                    __autoreleasing NSString *matchString = nil;
                    
                    // Maybe scan comment
                    if ([scanner scanString:startComment intoString:&matchString]) {
                        [localizedTranscription appendString:matchString];
                        if ([scanner scanUpToString:endComment intoString:&matchString])
                            [localizedTranscription appendString:matchString];
                        if ([scanner scanString:endComment intoString:&matchString])
                            [localizedTranscription appendString:matchString];
                        else {
                            fputs([[NSString stringWithFormat:@"%@: Error: Expected to read \"%@\"\n", devStringsPath, endComment] UTF8String], stderr);
                            break;
                        }
                        continue;
                    }
                    
                    // Maybe scan whitespace (outside of anything else)
                    if ([scanner scanCharactersFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet] intoString:&matchString]) {
                        [localizedTranscription appendString:matchString];
                        continue;
                    }
                    
                    // Scan tokens
                    NSString *unquotedStringToken = nil;
                    DMParseState previousParseState = parseState;
                    switch (parseState) {
                        case DMStateExpectingKey:
                        case DMStateExpectingValue:
                            // Read a quoted or unquoted string
                            if ([scanner scanString:@"\"" intoString:&matchString]) {
                                NSMutableString *quotedString = [NSMutableString string];
                                [quotedString appendString:matchString];
                                BOOL quotedStringTerminated = NO;
                                while (!quotedStringTerminated && ![scanner isAtEnd]) {
                                    if ([scanner scanUpToCharactersFromSet:maybeEndQuotedStringSet intoString:&matchString])
                                        [quotedString appendString:matchString];
                                    
                                    if ([scanner scanString:@"\"" intoString:&matchString]) // Final quote
                                        [quotedString appendString:matchString], quotedStringTerminated = YES;
                                    else if ([scanner scanString:@"\\" intoString:&matchString]) { // Skip the backslash and the next character
                                        [quotedString appendString:matchString];
                                        if ([scanner isAtEnd]) break;
                                        NSString *followingCharacterString = [scanner.string substringWithRange:NSMakeRange(scanner.scanLocation, 1)];
                                        [quotedString appendString:followingCharacterString];
                                        scanner.scanLocation += 1;
                                    } else
                                        break;
                                }
                                
                                if (quotedStringTerminated)
                                    unquotedStringToken = [quotedString substringWithRange:NSMakeRange(1, quotedString.length - 2)];
                                else
                                    fputs([[NSString stringWithFormat:@"%@: Error: Unterminated string: %@\n", devStringsPath, [quotedString substringToIndex:MIN(quotedString.length, 10u)]] UTF8String], stderr);
                                
                            } else if ([scanner scanUpToCharactersFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet] intoString:&matchString]) {
                                unquotedStringToken = matchString;
                            } else
                                fputs([[NSString stringWithFormat:@"%@: Error: Expected to read quoted string\n", devStringsPath] UTF8String], stderr);
                            
                            // Process the tokenized string
                            if (!unquotedStringToken)
                                break;
                            if (parseState == DMStateExpectingKey) {
                                lastDevFormatString = [[DMFormatString alloc] initWithString:unquotedStringToken];
                                if (!lastDevFormatString) {
                                    fputs([[NSString stringWithFormat:@"%@: Error: Invalid key format string %@\n", devStringsPath, unquotedStringToken] UTF8String], stderr);
                                    exit(EXIT_FAILURE);
                                }
                                [localizedTranscription appendFormat:@"\"%@\"", unquotedStringToken];
                                parseState++;
                            } else if (parseState == DMStateExpectingValue) {
                                NSCAssert(lastDevFormatString, nil);
                                DMMatchLevel matchLevel;
                                DMFormatString *localizedFormatString = [mapping bestLocalizedFormatStringForDevString:lastDevFormatString forContext:devStringsComponent matchLevel:&matchLevel];
                                if (!localizedFormatString) // Use development language
                                    localizedFormatString = [[DMFormatString alloc] initWithString:unquotedStringToken];
                                // TODO: Comment based on matchLevel
                                [localizedTranscription appendFormat:@"\"%@\"", [localizedFormatString stringByMatchingFormatString:lastDevFormatString]];
                                parseState++;
                            }
                            break;
                            
                        case DMStateExpectingEquals:
                            if ([scanner scanString:@"=" intoString:&matchString]) {
                                [localizedTranscription appendString:matchString];
                                parseState++;
                            } else
                                fputs([[NSString stringWithFormat:@"%@: Error: Expected to read equals\n", devStringsPath] UTF8String], stderr);
                            break;
                        case DMStateExpectingSemicolon:
                            if ([scanner scanString:@";" intoString:&matchString]) {
                                [localizedTranscription appendString:matchString];
                                parseState = DMStateExpectingKey;
                            } else
                                fputs([[NSString stringWithFormat:@"%@: Error: Expected to read semicolon\n", devStringsPath] UTF8String], stderr);
                            break;
                    }
                    
                    if (parseState == previousParseState)
                        break; // If we didn't progress, we have a problem
                }
                
                if (![scanner isAtEnd]) // We didn't process the file completely
                    break; // Break out of processing this strings file for all languages
                
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
                if (![devLanguageStringsFiles containsObject:languageSubfile]) {
                    fputs([[NSString stringWithFormat:@"Removing source directory strings file %@/%@\n", lproj, languageSubfile] UTF8String], stdout);
                    //[fm removeItemAtPath:stringsPath error:NULL]; // TODO: Uncomment post-testing
                }
            }
        }
        
        
        /*
         * Write orphaned translations somewhere?
         */
    }
    return EXIT_SUCCESS;
}


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
{ return [_allMappings count]; }

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

- (void)addLocalization:(DMFormatString *)localizedFormatString forDevString:(DMFormatString *)devFormatString context:(NSString *)tableName;
{
    if (isBetterLocalization(localizedFormatString, [_allMappings objectForKey:devFormatString], devFormatString))
        [_allMappings setObject:localizedFormatString forKey:devFormatString];
    
    NSMutableDictionary *table = [_mappingsByTableName objectForKey:tableName];
    if (!table)
        [_mappingsByTableName setObject:(table = [NSMutableDictionary dictionary]) forKey:tableName];
    if (isBetterLocalization(localizedFormatString, [table objectForKey:devFormatString], devFormatString))
        [table setObject:localizedFormatString forKey:devFormatString];
}

- (DMFormatString *)bestLocalizedFormatStringForDevString:(DMFormatString *)devFormatString forContext:(NSString *)tableName matchLevel:(out DMMatchLevel *)outMatchLevel;
{
    if (!devFormatString)
        return nil;
    DMFormatString *localizedFormatString = [[_mappingsByTableName objectForKey:tableName] objectForKey:devFormatString];
    if (outMatchLevel) *outMatchLevel = DMMatchSameContext;
    if (localizedFormatString)
        return localizedFormatString;
    
    localizedFormatString = [_allMappings objectForKey:devFormatString];
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
- (id)initWithString:(NSString *)potentialSpecifierString positionIfUnspecified:(NSInteger)fallbackPosition;
- (NSString *)stringWithExplicitPosition;
@property (readonly) DMFormatSpecifierType specifierType;
@property (readonly) NSInteger position; // 1-based
@property (readonly, copy) NSString *specifierString; // Starts with %
@end

@implementation DMFormatString {
    NSString *_rawString;
}

@synthesize formatSpecifierPositionsAreMonotonic = _formatSpecifierPositionsAreMonotonic;
@synthesize components = _components; // Array of NSString and DMFormatSpecifier objects interleaved
@synthesize formatSpecifiersByPosition = _formatSpecifiersByPosition;

- (id)initWithString:(NSString *)string;
{
    NSParameterAssert(string);
    if (!(self = [super init]))
        return nil;
    _rawString = [string copy];
    
    NSMutableArray *componentAccumulator = [NSMutableArray array];
    NSMutableString *literalAccumulator = [NSMutableString string];
    
    NSScanner *scanner = [NSScanner scannerWithString:string];
    scanner.charactersToBeSkipped = nil;
    NSInteger specifierPosition = 1;
    _formatSpecifierPositionsAreMonotonic = YES; // Can change in the loop
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
        BOOL (^scanSingleCharacter)() = ^{
            if ([scanner isAtEnd]) return NO;
            [formatSpecifierAccumulator appendString:[scanner.string substringWithRange:NSMakeRange(scanner.scanLocation, 1)]];
            scanner.scanLocation += 1; return YES;
        };
        scanSingleCharacter();
        
        DMFormatSpecifier *formatSpecifier = nil;
        while (!(formatSpecifier = [[DMFormatSpecifier alloc] initWithString:formatSpecifierAccumulator positionIfUnspecified:specifierPosition])) {
            if ([scanner scanUpToCharactersFromSet:[DMFormatSpecifier terminatingCharacterSet] intoString:&matchString])
                [formatSpecifierAccumulator appendString:matchString];
            if (!scanSingleCharacter())
                break;
        }
        
        if (formatSpecifier) {
            if (formatSpecifier.position != specifierPosition)
                _formatSpecifierPositionsAreMonotonic = NO;
            [componentAccumulator addObject:formatSpecifier];
            specifierPosition++;
        } else
            return nil; // Malformed format string
    }
    if (literalAccumulator.length)
        [componentAccumulator addObject:[literalAccumulator copy]];
    _components = [componentAccumulator copy];
    return self;
}

- (NSString *)stringByMatchingFormatString:(DMFormatString *)targetFormatString;
{
    NSMutableArray *matchedComponents = [NSMutableArray arrayWithCapacity:self.components.count];
    [self.components enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if ([obj isKindOfClass:[NSString class]])
            [matchedComponents addObject:obj];
        else if ([obj isKindOfClass:[DMFormatSpecifier class]]) {
            DMFormatSpecifier *targetSpecifier = [targetFormatString.formatSpecifiersByPosition objectForKey:[obj valueForKey:@"position"]];
            DMFormatSpecifier *chosenSpecifier = obj;
            if ([obj isEqual:targetSpecifier])
                chosenSpecifier = targetSpecifier;
            [matchedComponents addObject:(self.formatSpecifierPositionsAreMonotonic ? chosenSpecifier : chosenSpecifier.stringWithExplicitPosition)];
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
                [specifierMap setObject:component forKey:[component valueForKey:@"position"]];
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


@implementation DMFormatSpecifier {
    BOOL _positionWasExplicit;
}

@synthesize specifierType = _specifierType;
@synthesize position = _position;
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

- (id)initWithString:(NSString *)potentialSpecifierString positionIfUnspecified:(NSInteger)fallbackPosition;
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
    if ([potentialSpecifierString length] < 2)
        return nil;
    if ([potentialSpecifierString isEqual:@"%%"])
        return nil; // %% is a literal percent, not a specifier
    
    NSRange fullRange = NSMakeRange(0, [potentialSpecifierString length]);
    NSTextCheckingResult *formatStringMatch = nil, *displayPatternMatch = nil, *ruleEditorMatch = nil;
    formatStringMatch = [formatStringSpecifierRegExp firstMatchInString:potentialSpecifierString options:NSMatchingAnchored range:fullRange];
    if (formatStringMatch) {
        _specifierString = [potentialSpecifierString copy];
        _specifierType = DMFormatSpecifierFormatStringType;
        if ([formatStringMatch rangeAtIndex:1].length > 1)
            _positionWasExplicit = YES, _position = [[potentialSpecifierString substringWithRange:[formatStringMatch rangeAtIndex:1]] integerValue];
        else
            _position = fallbackPosition;
        return self;
    }
    displayPatternMatch = [displayPatternSpecifierRegExp firstMatchInString:potentialSpecifierString options:NSMatchingAnchored range:fullRange];
    if (displayPatternMatch) {
        _specifierString = [potentialSpecifierString copy];
        _specifierType = DMFormatSpecifierDisplayPatternType;
        _positionWasExplicit = YES, _position = [[potentialSpecifierString substringWithRange:[formatStringMatch rangeAtIndex:1]] integerValue];
        return self;
    }
    ruleEditorMatch = [ruleEditorSpecifierRegExp firstMatchInString:potentialSpecifierString options:NSMatchingAnchored range:fullRange];
    if (ruleEditorMatch) {
        _specifierString = [potentialSpecifierString copy];
        _specifierType = DMFormatSpecifierRuleEditorType;
        if ([formatStringMatch rangeAtIndex:1].length > 1)
            _positionWasExplicit = YES, _position = [[potentialSpecifierString substringWithRange:[formatStringMatch rangeAtIndex:1]] integerValue];
        else
            _position = fallbackPosition;
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
