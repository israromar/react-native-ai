//
//  MLCEngine.h
//  Pods
//
//  Created by Szymon Rybczak on 19/07/2024.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MLCEngine : NSObject

- (instancetype)init;

- (void)reloadWithModelPath:(NSString*)modelPath modelLib:(NSString*)modelLib;
- (void)reset;
- (void)unload;
- (void)abort:(NSString*)requestID;

- (void)chatCompletionWithMessages:(NSArray*)messages settings:(NSDictionary*)settings completion:(void (^)(id response))completion;
@end

NS_ASSUME_NONNULL_END
