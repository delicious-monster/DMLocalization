//
//  DMLocalizationMapping.h
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

#import <Foundation/Foundation.h>

@class DMFormatString;

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
