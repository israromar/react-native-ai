//
//  EngineState.mm
//  Pods
//
//  Created by Szymon Rybczak on 19/07/2024.
//

#import "EngineState.h"
#import "LLMEngine.h"

@implementation EngineState

- (instancetype)init {
  self = [super init];
  if (self) {
    _requestStateMap = [NSMutableDictionary new];
  }
  return self;
}

- (NSString*)chatCompletionWithJSONFFIEngine:(JSONFFIEngine*)jsonFFIEngine
                                     request:(NSDictionary*)request
                                  completion:(void (^)(NSString* response))completion {
  NSError* error;
  NSData* jsonData = [NSJSONSerialization dataWithJSONObject:request options:0 error:&error];
  if (error) {
    NSLog(@"Error encoding JSON: %@", error);
    return nil;
  }

  NSString* jsonRequest = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
  NSString* requestID = [[NSUUID UUID] UUIDString];

  // Store the completion handler in the requestStateMap
  self.requestStateMap[requestID] = completion;

  [jsonFFIEngine chatCompletion:jsonRequest requestID:requestID];
  
  return requestID;
}

- (void)streamCallbackWithResult:(NSString*)result {
  NSError* error;
  NSArray* responses = [NSJSONSerialization JSONObjectWithData:[result dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error];
  if (error) {
    NSLog(@"Error decoding JSON: %@", error);
    return;
  }

  for (NSDictionary* res in responses) {
    NSString* requestID = res[@"id"];
    void (^completion)(NSString*) = self.requestStateMap[requestID];
    if (completion) {
      // Check if this response contains usage data (indicates completion)
      NSDictionary* usage = res[@"usage"];
      if (usage) {
        NSLog(@"🟢 [EngineState] Detected completion with usage data: %@", usage);
        // For final response with usage, we need to notify completion with usage data
        // Create a special response format that includes usage
        NSDictionary* finalResponse = @{
          @"type": @"completion",
          @"originalResponse": result,
          @"usage": usage
        };
        NSError* jsonError;
        NSData* finalData = [NSJSONSerialization dataWithJSONObject:finalResponse options:0 error:&jsonError];
        if (!jsonError) {
          NSString* finalResult = [[NSString alloc] initWithData:finalData encoding:NSUTF8StringEncoding];
          NSLog(@"🟢 [EngineState] Sending completion response with usage");
          completion(finalResult);
        } else {
          NSLog(@"🔴 [EngineState] Error creating final response JSON: %@", jsonError);
          completion(result);
        }
        [self.requestStateMap removeObjectForKey:requestID];
      } else {
        // For streaming responses, check if this is a finish without usage
        NSArray* choices = res[@"choices"];
        BOOL isFinishedWithoutUsage = NO;
        if ([choices isKindOfClass:[NSArray class]] && choices.count > 0) {
          NSDictionary* choice = choices[0];
          NSString* finishReason = choice[@"finish_reason"];
          isFinishedWithoutUsage = (finishReason != nil && ![finishReason isEqual:[NSNull null]]);
        }
        
        if (isFinishedWithoutUsage) {
          NSLog(@"🟡 [EngineState] Detected finish without usage - deferring completion");
          // Don't call completion yet, wait for usage data
        } else {
          // For normal streaming responses, pass through as normal
          completion(result);
        }
      }
    }
  }
}

- (void)abortRequest:(NSString*)requestID {
  void (^completion)(NSString*) = self.requestStateMap[requestID];
  if (completion) {
    NSLog(@"🛑 [EngineState] Sending cancellation response for request: %@", requestID);
    
    // Create a cancellation response
    NSDictionary* cancelResponse = @{
      @"type": @"cancelled",
      @"id": requestID
    };
    
    NSError* jsonError;
    NSData* cancelData = [NSJSONSerialization dataWithJSONObject:@[cancelResponse] options:0 error:&jsonError];
    if (!jsonError) {
      NSString* cancelResult = [[NSString alloc] initWithData:cancelData encoding:NSUTF8StringEncoding];
      completion(cancelResult);
    }
    
    // Remove the completion handler
    [self.requestStateMap removeObjectForKey:requestID];
  }
}

@end
