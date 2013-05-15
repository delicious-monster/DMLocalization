//
//  DMStringsFileScanner.h
//  Library
//
//  Created by William Shipley on 5/15/13.
//  Copyright (c) 2013 Delicious Monster Software. All rights reserved.
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
