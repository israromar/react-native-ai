//
//  MLCEngine.h
//  Pods
//
//  Created by Szymon Rybczak on 19/07/2024.
//

#import "LLMEngine.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface EngineState : NSObject
@property(nonatomic, strong) NSMutableDictionary<NSString*, id>* requestStateMap;

- (NSString*)chatCompletionWithJSONFFIEngine:(JSONFFIEngine*)jsonFFIEngine
                                     request:(NSDictionary*)request
                                  completion:(void (^)(NSString* response))completion;
- (void)streamCallbackWithResult:(NSString*)result;
- (void)abortRequest:(NSString*)requestID;
@end
NS_ASSUME_NONNULL_END
