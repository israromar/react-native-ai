//
//  MLCEngine.mm
//  Pods
//
//  Created by Szymon Rybczak on 19/07/2024.
//

#import "MLCEngine.h"
#import "BackgroundWorker.h"
#import "EngineState.h"
#import "LLMEngine.h"

// Private class extension for MLCEngine
@interface MLCEngine ()
@property(nonatomic, strong) EngineState* state;
@property(nonatomic, strong) JSONFFIEngine* jsonFFIEngine;
@property(nonatomic, strong) NSMutableArray<NSThread*>* threads;
@property(nonatomic, strong) NSString* currentRequestID;
@end

@implementation MLCEngine

- (instancetype)init {
  self = [super init];
  if (self) {
    _state = [[EngineState alloc] init];
    _jsonFFIEngine = [[JSONFFIEngine alloc] init];
    _threads = [NSMutableArray array];

    [_jsonFFIEngine initBackgroundEngine:^(NSString* _Nullable result) {
      [self.state streamCallbackWithResult:result];
    }];

    BackgroundWorker* backgroundWorker = [[BackgroundWorker alloc] initWithTask:^{
      [NSThread setThreadPriority:1.0];
      [self.jsonFFIEngine runBackgroundLoop];
    }];

    BackgroundWorker* backgroundStreamBackWorker = [[BackgroundWorker alloc] initWithTask:^{
      [self.jsonFFIEngine runBackgroundStreamBackLoop];
    }];

    backgroundWorker.qualityOfService = NSQualityOfServiceUserInteractive;
    [_threads addObject:backgroundWorker];
    [_threads addObject:backgroundStreamBackWorker];
    [backgroundWorker start];
    [backgroundStreamBackWorker start];
  }
  return self;
}

- (void)dealloc {
  [self.jsonFFIEngine exitBackgroundLoop];
}

- (void)reloadWithModelPath:(NSString*)modelPath modelLib:(NSString*)modelLib {
  NSString* engineConfig =
      [NSString stringWithFormat:@"{\"model\": \"%@\", \"model_lib\": \"system://%@\", \"mode\": \"interactive\"}", modelPath, modelLib];
  [self.jsonFFIEngine reload:engineConfig];
}

- (void)reset {
  [self.jsonFFIEngine reset];
}

- (void)unload {
  [self.jsonFFIEngine unload];
}

- (void)abort:(NSString*)requestID {
  // If no specific request ID provided, use the current one
  NSString* targetRequestID = (requestID && requestID.length > 0) ? requestID : self.currentRequestID;

  if (targetRequestID) {
    NSLog(@"🛑 [MLCEngine] Aborting request: %@", targetRequestID);
    
    // First abort at the MLC-AI level
    [self.jsonFFIEngine abort:targetRequestID];
    
    // Then notify the completion handler that the request was cancelled
    [self.state abortRequest:targetRequestID];
    
    // Clear the current request ID since we've aborted it
    if ([targetRequestID isEqualToString:self.currentRequestID]) {
      self.currentRequestID = nil;
    }
  } else {
    NSLog(@"🟡 [MLCEngine] No request ID available for abort");
  }
}

- (void)chatCompletionWithMessages:(NSArray*)messages settings:(NSDictionary*)settings completion:(void (^)(NSString* response))completion {
  // Create request with messages and settings
  NSMutableDictionary* request = [@{@"messages" : messages} mutableCopy];
  
  // Apply settings with fallback to defaults
  request[@"temperature"] = settings[@"temperature"] ?: @0.6;
  
  if (settings[@"maxTokens"]) {
    request[@"max_tokens"] = settings[@"maxTokens"];
  }
  
  if (settings[@"topP"]) {
    request[@"top_p"] = settings[@"topP"];
  }
  
  if (settings[@"frequencyPenalty"]) {
    request[@"frequency_penalty"] = settings[@"frequencyPenalty"];
  }
  
  if (settings[@"presencePenalty"]) {
    request[@"presence_penalty"] = settings[@"presencePenalty"];
  }
  
  // Log only in debug mode
  #ifdef DEBUG
    NSLog(@"🔵 [MLCEngine] Chat completion request: %@", request);
  #endif

  // Track the request ID for potential cancellation
  NSString* requestID = [self.state chatCompletionWithJSONFFIEngine:self.jsonFFIEngine request:request completion:completion];
  self.currentRequestID = requestID;
}

@end
