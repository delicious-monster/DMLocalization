//  xibLocalizationPostprocessor.m
//  Library
//
//  Created by William Shipley on 4/14/08.
//  Copyright 2008 Delicious Monster Software. All rights reserved.

#import <Cocoa/Cocoa.h>

static NSString *const DMDoNotLocalizeMarker = @"??";

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "Usage: %s file.strings\n", argv[0]);
            exit (-1);   
        }

        NSError *error = nil;
        NSStringEncoding usedEncoding;
        NSString *const rawXIBStrings = [NSString stringWithContentsOfFile:@(argv[1]) usedEncoding:&usedEncoding error:&error];
        if (!rawXIBStrings) {
            fprintf(stderr, "Error reading %s: %s\n", argv[1], error.localizedDescription.UTF8String);
            exit (-1);
        }
                                   
        NSMutableString *const outputStrings = [NSMutableString new];
        NSUInteger lineCount = 0;
        NSString *lastComment = nil;
        for (NSString *line in [rawXIBStrings componentsSeparatedByString:@"\n"]) {
            lineCount++;
            
            if ([line hasPrefix:@"/*"]) { // eg: /* Class = "NSMenuItem"; title = "Quit Library"; ObjectID = "136"; */
                lastComment = line;
                continue;

            } else if (line.length == 0) {
                lastComment = nil;
                continue;

            } else if ([line hasPrefix:@"\""] && [line hasSuffix:@"\";"]) { // eg: "136.title" = "Quit Library";
                
                const NSRange quoteEqualsQuoteRange = [line rangeOfString:@"\" = \""];
                if (quoteEqualsQuoteRange.length && NSMaxRange(quoteEqualsQuoteRange) < line.length - 1) {
                    NSString *stringNeedingLocalization = [line substringFromIndex:NSMaxRange(quoteEqualsQuoteRange)]; // chop off leading: "136.title" = "
                    stringNeedingLocalization = [stringNeedingLocalization substringToIndex:stringNeedingLocalization.length - 2]; // chop off trailing: ";
                    if ([stringNeedingLocalization rangeOfString:DMDoNotLocalizeMarker].length)
                        continue;

                    if (lastComment) {
                        [outputStrings appendString:@"\n"];
                        [outputStrings appendString:lastComment];
                        [outputStrings appendString:@"\n"];
                    }
                    [outputStrings appendString:line];
                    [outputStrings appendString:@"\n"];
                    continue;
                }
            }
            
            NSLog(@"Warning: skipped garbage input line %ld, contents: \"%@\"", (long)lineCount, line);
        }
        
        if (outputStrings.length && ![outputStrings writeToFile:@(argv[1]) atomically:NO encoding:NSUTF8StringEncoding error:&error]) {
            fprintf(stderr, "Error writing %s: %s\n", argv[1], error.localizedDescription.UTF8String);
            exit (-1);
        }
    }
}
