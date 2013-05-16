//  xibLocalizationPostprocessor.m
//  Library
//
//  Created by William Shipley on 4/14/08.
//  Copyright 2008 Delicious Monster Software. All rights reserved.

#import <Cocoa/Cocoa.h>

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

        NSString *const doNotLocalizeMarker = @"??";
        NSArray *const commentPrefixesForStringsThatReallyDoNotNeedToBeLocalized = @[
                                                                                     // Skip examples:
                                                                                     /* Class = "NSTextFieldCell"; title = "Text Cell"; ObjectID = "532"; */
                                                                                     @"/* Class = \"NSTextFieldCell\"; title = \"Text Cell\";",
                                                                                     /* Class = "NSBox"; title = "Box"; ObjectID = "1162"; */
                                                                                     @"/* Class = \"NSBox\"; title = \"Box\";",
                                                                                     /* Class = "NSButtonCell"; title = "Radio"; ObjectID = "472"; */
                                                                                     @"/* Class = \"NSButtonCell\"; title = \"Radio\";",
                                                                                     /* Class = "NSMenu"; title = "ANYTHING"; ObjectID = "15"; */
                                                                                     @"/* Class = \"NSMenu\"; title = \"",
                                                                                     /* Class = "NSWindow"; title = "Window"; ObjectID = "80"; */
                                                                                     @"/* Class = \"NSWindow\"; title = \"Window\";",
                                                                                     /* Class = "NSViewController"; title = "ANYTHING"; ObjectID = "1090"; */
                                                                                     @"/* Class = \"NSViewController\"; title = \"",
                                                                                     // older style (starts with "Item1")
                                                                                     /* Class = "NSMenuItem"; title = "Item1"; ObjectID = "87"; */
                                                                                     @"/* Class = \"NSMenuItem\"; title = \"Item1\";",
                                                                                     /* Class = "NSMenuItem"; title = "Item2"; ObjectID = "197"; */
                                                                                     @"/* Class = \"NSMenuItem\"; title = \"Item2\";",
                                                                                     /* Class = "NSMenuItem"; title = "Item3"; ObjectID = "324"; */
                                                                                     @"/* Class = \"NSMenuItem\"; title = \"Item3\";",
                                                                                     // newer style (starts with "Item", which might be valid, so skip it)
                                                                                     /* Class = "NSMenuItem"; title = "Item 2"; ObjectID = "197"; */
                                                                                     @"/* Class = \"NSMenuItem\"; title = \"Item 2\";",
                                                                                     /* Class = "NSMenuItem"; title = "Item 3"; ObjectID = "324"; */
                                                                                     @"/* Class = \"NSMenuItem\"; title = \"Item 3\";",
                                                                                     ];

        NSMutableString *const outputStrings = [NSMutableString new];
        NSUInteger lineCount = 0;
        NSString *lastComment = nil;
        for (NSString *line in [rawXIBStrings componentsSeparatedByString:@"\n"]) {
            lineCount++;
            
            if ([line hasPrefix:@"/*"]) { // eg: /* Class = "NSMenuItem"; title = "Quit Library"; ObjectID = "136"; */
                lastComment = line;

            } else if (line.length == 0) {
                lastComment = nil;

            } else if ([line hasPrefix:@"\""] && [line hasSuffix:@"\";"]) { // eg: "136.title" = "Quit Library";

                // see if this contains our marker ("??") for placeholder strings that shouldn't be localized
                if ([line rangeOfString:doNotLocalizeMarker].length) {
                    printf("Info: skipped input line %ld, ‘??’ found: “%s”\n", (long)lineCount, line.UTF8String);
                    continue;
                }
                // see if this is one of the common garbage strings IB inserts in XIBs, so we don't force our
                BOOL skipLine = NO;
                for (NSString *skipCommentPrefix in commentPrefixesForStringsThatReallyDoNotNeedToBeLocalized)
                    if ([lastComment hasPrefix:skipCommentPrefix]) {
                        skipLine = YES;
                        break;
                    }
                if (skipLine) {
                    printf("Info: skipped input line %ld, comment matched blacklist: “%s”\n", (long)lineCount, lastComment.UTF8String);
                    continue;
                }

                [outputStrings appendString:@"\n"];
                if (lastComment) {
                    [outputStrings appendString:lastComment]; [outputStrings appendString:@"\n"];
                }
                [outputStrings appendString:line]; [outputStrings appendString:@"\n"];

            } else
                printf("Warning: skipped garbage input line %ld, contents: “%s”\n", (long)lineCount, line.UTF8String);
        }
        
        if (outputStrings.length) {
            if (![outputStrings writeToFile:@(argv[1]) atomically:NO encoding:NSUTF8StringEncoding error:&error]) {
                fprintf(stderr, "Error writing %s: %s\n", argv[1], error.localizedDescription.UTF8String);
                exit (-1);
            }

        } else // remove strings file if it's now totally empty!
            [[NSFileManager defaultManager] removeItemAtPath:[[NSFileManager defaultManager] stringWithFileSystemRepresentation:argv[1] length:strlen(argv[1])] error:NULL];

    }
}
