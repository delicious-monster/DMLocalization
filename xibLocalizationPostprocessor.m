//  xibLocalizationPostprocessor.m
//  Library
//
//  Created by William Shipley on 4/14/08.
//  Copyright 2008 Delicious Monster Software. All rights reserved.

#import <Cocoa/Cocoa.h>

#define LOG_INFO 1


int main(int argc, const char *argv[])
{
    if (argc != 2) {
        fprintf(stderr, "Usage: %s file.strings\n", argv[0]);
        return -1;
    }

    @autoreleasepool {
        NSString *const filePath = @(argv[1]);
        NSString *const filename = filePath.lastPathComponent;

        __autoreleasing NSError *error = nil;
        NSString *const rawXIBStrings = [NSString stringWithContentsOfFile:filePath usedEncoding:NULL error:&error];
        if (!rawXIBStrings) {
            fprintf(stderr, "%s error: %s\n", filePath.UTF8String, error.localizedDescription.UTF8String);
            return -1;
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
                                                                                     /* Class = "NSWindow"; title = "Window"; ObjectID = "80"; */
                                                                                     @"/* Class = \"NSWindow\"; title = \"Window\";",
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
        __block NSUInteger lineCount = 0;
        __block NSString *lastComment = nil;
        [rawXIBStrings enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
            lineCount++;
            
            if ([line hasPrefix:@"/*"]) { // eg: /* Class = "NSMenuItem"; title = "Quit Library"; ObjectID = "136"; */
                lastComment = line;

            } else if (line.length == 0) {
                lastComment = nil;

            } else if ([line hasPrefix:@"\""] && [line hasSuffix:@"\";"]) { // eg: "136.title" = "Quit Library";

                // see if this contains our marker ("??") for placeholder strings that shouldn't be localized
                if ([line rangeOfString:doNotLocalizeMarker].length) {
#if LOG_INFO
                    printf("%s:%lu info: skipped line, ‘??’ found: “%s”\n", filename.UTF8String, (unsigned long)lineCount, line.UTF8String);
#endif
                    return;
                }
                // see if this is one of the common garbage strings IB inserts in XIBs, so we don't force our
                BOOL skipLine = NO;
                for (NSString *skipCommentPrefix in commentPrefixesForStringsThatReallyDoNotNeedToBeLocalized) {
                    skipLine = [lastComment hasPrefix:skipCommentPrefix];
                    if (skipLine)
                        break;
                }
                if (!skipLine && ![filename isEqualToString:@"MainMenu.strings"]) // NSMenu titles are ONLY shown in main menu, AFAIK.
                /* Class = "NSMenu"; title = "ANYTHING"; ObjectID = "15"; */
                    skipLine = [lastComment hasPrefix:@"/* Class = \"NSMenu\"; title = \""];
                if (skipLine) {
#if LOG_INFO
                    printf("%s:%lu info: skipped line, comment matched blacklist: “%s”\n", filename.UTF8String, (unsigned long)lineCount, lastComment.UTF8String);
#endif
                    return;
                }

                [outputStrings appendString:@"\n"];
                if (lastComment) {
                    [outputStrings appendString:lastComment]; [outputStrings appendString:@"\n"];
                }
                [outputStrings appendString:line]; [outputStrings appendString:@"\n"];

            } else
                printf("%s:%lu warning: skipped garbage line, contents: “%s”\n", filename.UTF8String, (unsigned long)lineCount, line.UTF8String);
        }];
        
        if (outputStrings.length) {
            if (![outputStrings writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
                fprintf(stderr, "%s: Error writing: %s\n", filePath.UTF8String, error.localizedDescription.UTF8String);
                return -1;
            }

        } else { // remove strings file if it's now totally empty!
            if (![[NSFileManager defaultManager] removeItemAtPath:filePath error:&error]) {
                fprintf(stderr, "%s: Error deleting: %s\n", filePath.UTF8String, error.localizedDescription.UTF8String);
                return-1;
            }
        }
        return 0;
    }
}
