//
//  DMFormatSpecifier.m
//  Library
//
//  Created by William Shipley on 5/15/13.
//  Copyright (c) 2013 Delicious Monster Software. All rights reserved.
//

#import "DMFormatSpecifier.h"


@implementation DMFormatSpecifier

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
