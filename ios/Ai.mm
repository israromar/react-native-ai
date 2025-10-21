#import "Ai.h"
#import "MLCEngine.h"
#import <SafariServices/SafariServices.h>

@interface Ai ()

@property(nonatomic, strong) MLCEngine* engine;
@property(nonatomic, strong) NSURL* bundleURL;
@property(nonatomic, strong) NSString* modelPath;
@property(nonatomic, strong) NSString* modelLib;
@property(nonatomic, strong) NSString* displayText;
@property(nonatomic, strong) NSString* currentRequestID;

@end

@implementation Ai

{
  bool hasListeners;
}

RCT_EXPORT_MODULE()

+ (BOOL)requiresMainQueueSetup {
  return YES;
}

- (NSArray<NSString*>*)supportedEvents {
  return @[ @"onChatUpdate", @"onChatComplete", @"onDownloadStart", @"onDownloadComplete", @"onDownloadProgress", @"onDownloadError" ];
}

- (void)startObserving {
  hasListeners = YES;
}

- (void)stopObserving {
  hasListeners = NO;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _engine = [[MLCEngine alloc] init];

    // Get the Documents directory path
    NSArray* paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString* documentsDirectory = [paths firstObject];
    _bundleURL = [NSURL fileURLWithPath:[documentsDirectory stringByAppendingPathComponent:@"bundle"]];

    // Create bundle directory if it doesn't exist
    NSError* dirError;
    [[NSFileManager defaultManager] createDirectoryAtPath:[_bundleURL path] withIntermediateDirectories:YES attributes:nil error:&dirError];
    if (dirError) {
      NSLog(@"Error creating bundle directory: %@", dirError);
    }

    // Copy the config file from the app bundle to Documents if it doesn't exist yet
    NSURL* bundleConfigURL = [[[NSBundle mainBundle] bundleURL] URLByAppendingPathComponent:@"bundle/mlc-app-config.json"];
    NSURL* configURL = [_bundleURL URLByAppendingPathComponent:@"mlc-app-config.json"];

    NSError* copyError;
    [[NSFileManager defaultManager] removeItemAtURL:configURL error:nil]; // Remove existing file if it exists
    [[NSFileManager defaultManager] copyItemAtURL:bundleConfigURL toURL:configURL error:&copyError];
    if (copyError) {
      NSLog(@"Error copying config file: %@", copyError);
    }

    // Read and parse JSON
    NSData* jsonData = [NSData dataWithContentsOfURL:configURL];
    if (jsonData) {
      NSError* error;
      NSDictionary* jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];

      if (!error && [jsonDict isKindOfClass:[NSDictionary class]]) {
        NSArray* modelList = jsonDict[@"model_list"];
        if ([modelList isKindOfClass:[NSArray class]] && modelList.count > 0) {
          NSDictionary* firstModel = modelList[0];
          _modelPath = firstModel[@"model_path"];
          _modelLib = firstModel[@"model_lib"];
        }
      }
    }
  }
  return self;
}

- (NSDictionary*)parseResponseString:(NSString*)responseString {
  NSData* jsonData = [responseString dataUsingEncoding:NSUTF8StringEncoding];
  NSError* error;
  
  // First, try to parse as our special response formats
  NSDictionary* jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
  if (!error && [jsonDict isKindOfClass:[NSDictionary class]]) {
    NSString* type = jsonDict[@"type"];
    if ([type isEqualToString:@"completion"]) {
      NSLog(@"🟢 [ParseResponse] Processing completion response with usage data");
      // This is a completion response with usage data
      NSString* originalResponse = jsonDict[@"originalResponse"];
      NSDictionary* usage = jsonDict[@"usage"];
      
      // Parse the original response to get content
      NSDictionary* originalParsed = [self parseOriginalResponseString:originalResponse];
      if (originalParsed) {
        NSMutableDictionary* result = [originalParsed mutableCopy];
        result[@"usage"] = usage;
        result[@"isFinished"] = @(YES);
        NSLog(@"🟢 [ParseResponse] Returning completion result with usage: %@", usage);
        return result;
      }
    } else if ([type isEqualToString:@"cancelled"]) {
      NSLog(@"🛑 [ParseResponse] Processing cancellation response");
      // This is a cancellation response
      return @{
        @"content": @"",
        @"isFinished": @(YES),
        @"isCancelled": @(YES)
      };
    }
  }
  
  // Try to parse as array (cancellation response format)
  NSArray* jsonArray = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];
  if (!error && [jsonArray isKindOfClass:[NSArray class]] && jsonArray.count > 0) {
    NSDictionary* firstResponse = jsonArray[0];
    if ([firstResponse isKindOfClass:[NSDictionary class]]) {
      NSString* type = firstResponse[@"type"];
      if ([type isEqualToString:@"cancelled"]) {
        NSLog(@"🛑 [ParseResponse] Processing array-format cancellation response");
        return @{
          @"content": @"",
          @"isFinished": @(YES),
          @"isCancelled": @(YES)
        };
      }
    }
  }
  
  // Fall back to parsing as normal streaming response
  return [self parseOriginalResponseString:responseString];
}

- (NSDictionary*)parseOriginalResponseString:(NSString*)responseString {
  NSData* jsonData = [responseString dataUsingEncoding:NSUTF8StringEncoding];
  NSError* error;
  NSArray* jsonArray = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];

  if (error) {
    NSLog(@"Error parsing JSON: %@", error);
    return nil;
  }

  if (jsonArray.count > 0) {
    NSDictionary* responseDict = jsonArray[0];
    NSArray* choices = responseDict[@"choices"];
    if (choices.count > 0) {
      NSDictionary* choice = choices[0];
      NSDictionary* delta = choice[@"delta"];
      NSString* content = delta[@"content"];
      NSString* finishReason = choice[@"finish_reason"];

      BOOL isFinished = (finishReason != nil && ![finishReason isEqual:[NSNull null]]);

      NSMutableDictionary* result = [NSMutableDictionary dictionary];
      result[@"content"] = content ?: @"";
      result[@"isFinished"] = @(isFinished);
      if (finishReason && ![finishReason isEqual:[NSNull null]]) {
        result[@"finishReason"] = finishReason;
      }

      return result;
    }
  }

  return nil;
}

RCT_EXPORT_METHOD(doGenerate : (NSString*)instanceId messages : (NSArray<NSDictionary*>*)messages settings : (NSDictionary*)settings resolve : (RCTPromiseResolveBlock)
                      resolve reject : (RCTPromiseRejectBlock)reject) {
  NSLog(@"Generating for instance ID: %@, with messages: %@, settings: %@", instanceId, messages, settings);
  _displayText = @"";
  __block BOOL hasResolved = NO;
  __block NSDictionary* finalUsage = nil;

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSURL* modelLocalURL = [self.bundleURL URLByAppendingPathComponent:self.modelPath];
    NSString* modelLocalPath = [modelLocalURL path];

    [self.engine reloadWithModelPath:modelLocalPath modelLib:self.modelLib];

    [self.engine chatCompletionWithMessages:messages settings:settings
                                 completion:^(id response) {
                                   if ([response isKindOfClass:[NSString class]]) {
                                     NSDictionary* parsedResponse = [self parseResponseString:response];
                                     if (parsedResponse) {
                                       NSString* content = parsedResponse[@"content"];
                                       BOOL isFinished = [parsedResponse[@"isFinished"] boolValue];
                                       NSDictionary* usage = parsedResponse[@"usage"];
                                       NSString* finishReason = parsedResponse[@"finishReason"];

                                       if (content && [content length] > 0) {
                                         self.displayText = [self.displayText stringByAppendingString:content];
                                       }

                                       if (usage) {
                                         finalUsage = usage;
                                       }

                                       if (isFinished && !hasResolved) {
                                         hasResolved = YES;
                                         // Return result with usage data and finish reason
                                         NSMutableDictionary* result = [NSMutableDictionary dictionary];
                                         result[@"text"] = self.displayText;
                                         result[@"usage"] = finalUsage ?: @{};
                                         if (finishReason) {
                                           result[@"finishReason"] = finishReason;
                                         }
                                         resolve(result);
                                       }

                                     } else {
                                       if (!hasResolved) {
                                         hasResolved = YES;
                                         reject(@"PARSE_ERROR", @"Failed to parse response", nil);
                                       }
                                     }
                                   } else {
                                     if (!hasResolved) {
                                       hasResolved = YES;
                                       reject(@"INVALID_RESPONSE", @"Received an invalid response type", nil);
                                     }
                                   }
                                 }];
  });
}

RCT_EXPORT_METHOD(doStream : (NSString*)instanceId messages : (NSArray<NSDictionary*>*)messages settings : (NSDictionary*)settings resolve : (RCTPromiseResolveBlock)
                      resolve reject : (RCTPromiseRejectBlock)reject) {

  NSLog(@"Streaming for instance ID: %@, with messages: %@, settings: %@", instanceId, messages, settings);

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    __block BOOL hasResolved = NO;

    NSURL* modelLocalURL = [self.bundleURL URLByAppendingPathComponent:self.modelPath];
    NSString* modelLocalPath = [modelLocalURL path];

    [self.engine reloadWithModelPath:modelLocalPath modelLib:self.modelLib];

    [self.engine chatCompletionWithMessages:messages settings:settings
                                 completion:^(id response) {
                                   if ([response isKindOfClass:[NSString class]]) {
                                     NSDictionary* parsedResponse = [self parseResponseString:response];
                                     if (parsedResponse) {
                                       NSString* content = parsedResponse[@"content"];
                                       BOOL isFinished = [parsedResponse[@"isFinished"] boolValue];
                                       BOOL isCancelled = [parsedResponse[@"isCancelled"] boolValue];
                                       NSDictionary* usage = parsedResponse[@"usage"];
                                       NSString* finishReason = parsedResponse[@"finishReason"];

                                       if (content && [content length] > 0) {
                                         self.displayText = [self.displayText stringByAppendingString:content];
                                         if (self->hasListeners) {
                                           [self sendEventWithName:@"onChatUpdate" body:@{@"content" : content}];
                                         }
                                       }

                                       if (isFinished && !hasResolved) {
                                         hasResolved = YES;
                                         if (self->hasListeners) {
                                           // Send completion event with usage data and finish reason if available
                                           NSMutableDictionary* completionBody = [NSMutableDictionary dictionary];
                                           if (isCancelled) {
                                             NSLog(@"🛑 [DoStream] Sending cancellation event");
                                             completionBody[@"cancelled"] = @(YES);
                                           } else if (usage) {
                                             NSLog(@"🟢 [DoStream] Sending completion event with usage: %@", usage);
                                             completionBody[@"usage"] = usage;
                                           } else {
                                             NSLog(@"🟡 [DoStream] Sending completion event without usage data");
                                           }
                                           if (finishReason) {
                                             completionBody[@"finishReason"] = finishReason;
                                           }
                                           NSLog(@"🔵 [DoStream] Final completion body: %@", completionBody);
                                           [self sendEventWithName:@"onChatComplete" body:completionBody];
                                         }

                                         resolve(@"");
                                         return;
                                       }
                                     } else {
                                       if (!hasResolved) {
                                         hasResolved = YES;
                                         reject(@"PARSE_ERROR", @"Failed to parse response", nil);
                                       }
                                     }
                                   } else {
                                     if (!hasResolved) {
                                       hasResolved = YES;
                                       reject(@"INVALID_RESPONSE", @"Received an invalid response type", nil);
                                     }
                                   }
                                 }];
  });
}

RCT_EXPORT_METHOD(getModel : (NSString*)name resolve : (RCTPromiseResolveBlock)resolve reject : (RCTPromiseRejectBlock)reject) {
  // Read app config from Documents directory
  NSURL* configURL = [self.bundleURL URLByAppendingPathComponent:@"mlc-app-config.json"];
  NSData* jsonData = [NSData dataWithContentsOfURL:configURL];

  if (!jsonData) {
    reject(@"Model not found", @"Failed to read app config", nil);
    return;
  }

  NSError* error;
  NSDictionary* appConfig = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];

  if (error) {
    reject(@"Model not found", @"Failed to parse app config", error);
    return;
  }

  // Find model record
  NSArray* modelList = appConfig[@"model_list"];
  NSDictionary* modelConfig = nil;

  for (NSDictionary* model in modelList) {
    if ([model[@"model_id"] isEqualToString:name]) {
      modelConfig = model;
      break;
    }
  }

  if (!modelConfig) {
    reject(@"Model not found", @"Didn't find the model", nil);
    return;
  }

  // Return a JSON object with details
  NSDictionary* modelInfo = @{@"modelId" : modelConfig[@"model_id"], @"modelLib" : modelConfig[@"model_lib"]};

  resolve(modelInfo);
}

RCT_EXPORT_METHOD(getModels : (RCTPromiseResolveBlock)resolve reject : (RCTPromiseRejectBlock)reject) {
  NSURL* configURL = [_bundleURL URLByAppendingPathComponent:@"mlc-app-config.json"];

  // Read and parse JSON
  NSData* jsonData = [NSData dataWithContentsOfURL:configURL];
  if (!jsonData) {
    reject(@"error", @"Failed to read JSON data", nil);
    return;
  }

  NSError* error;
  NSDictionary* jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];

  if (error || ![jsonDict isKindOfClass:[NSDictionary class]]) {
    reject(@"error", @"Failed to parse JSON", error);
    return;
  }

  NSArray* modelList = jsonDict[@"model_list"];
  if (![modelList isKindOfClass:[NSArray class]]) {
    reject(@"error", @"model_list is missing or invalid", nil);
    return;
  }

  // Create mutable copy of model list to add download status
  NSMutableArray* enhancedModelList = [NSMutableArray arrayWithCapacity:modelList.count];

  for (NSDictionary* model in modelList) {
    NSMutableDictionary* enhancedModel = [model mutableCopy];
    NSString* modelId = model[@"model_id"];

    if (modelId) {
      // Check if model directory exists
      NSURL* modelDirURL = [_bundleURL URLByAppendingPathComponent:modelId];
      BOOL isDownloaded = [[NSFileManager defaultManager] fileExistsAtPath:[modelDirURL path]];

      // Enhanced model download verification
      [enhancedModel setObject:@([self isModelCompletelyDownloaded:modelId]) forKey:@"downloaded"];
    } else {
      [enhancedModel setObject:@NO forKey:@"downloaded"];
    }

    [enhancedModelList addObject:enhancedModel];
  }

  NSLog(@"models: %@", enhancedModelList);
  resolve(enhancedModelList);
}

RCT_EXPORT_METHOD(prepareModel : (NSString*)instanceId resolve : (RCTPromiseResolveBlock)resolve reject : (RCTPromiseRejectBlock)reject) {
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    @try {
      // Clean up any incomplete download before proceeding
      if (![self isModelCompletelyDownloaded:instanceId]) {
        NSURL* modelDirURL = [self.bundleURL URLByAppendingPathComponent:instanceId];
        if ([[NSFileManager defaultManager] fileExistsAtPath:[modelDirURL path]]) {
          NSError* deleteError;
          [[NSFileManager defaultManager] removeItemAtURL:modelDirURL error:&deleteError];
          if (deleteError) {
            NSLog(@"⚠️ Failed to clean incomplete model %@: %@", instanceId, deleteError.localizedDescription);
          } else {
            NSLog(@"🧹 Cleaned incomplete download for model: %@", instanceId);
          }
        }
      }
      
      // Read app config
      NSURL* configURL = [self.bundleURL URLByAppendingPathComponent:@"mlc-app-config.json"];
      NSData* jsonData = [NSData dataWithContentsOfURL:configURL];

      if (!jsonData) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"MODEL_ERROR", @"Failed to read app config", nil);
        });
        return;
      }

      NSError* error;
      NSDictionary* appConfig = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];

      if (error) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"MODEL_ERROR", @"Failed to parse app config", error);
        });
        return;
      }

      // Find model record
      NSArray* modelList = appConfig[@"model_list"];
      NSDictionary* modelRecord = nil;

      for (NSDictionary* model in modelList) {
        if ([model[@"model_id"] isEqualToString:instanceId]) {
          modelRecord = model;
          break;
        }
      }

      if (!modelRecord) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"MODEL_ERROR", @"There's no record for requested model", nil);
        });
        return;
      }

      // Check if model directory exists in app bundle (bundled model)
      NSURL* appBundleModelDir = [[[NSBundle mainBundle] bundleURL] URLByAppendingPathComponent:[NSString stringWithFormat:@"bundle/%@", instanceId]];
      BOOL isAppBundledModel = [[NSFileManager defaultManager] fileExistsAtPath:[appBundleModelDir path]];
      
      // If model is bundled, copy it to Documents directory
      if (isAppBundledModel) {
        NSLog(@"Found bundled model for %@, copying to Documents", instanceId);
        NSURL* docsModelDir = [self.bundleURL URLByAppendingPathComponent:instanceId];
        NSURL* docsConfigFile = [docsModelDir URLByAppendingPathComponent:@"mlc-chat-config.json"];
        
        // Check if we need to copy (if model dir doesn't exist in docs or config is missing)
        if (![[NSFileManager defaultManager] fileExistsAtPath:[docsConfigFile path]]) {
          NSLog(@"Copying bundled model %@ from app bundle to Documents", instanceId);
          NSError* copyError;
          // Remove existing directory if it exists
          [[NSFileManager defaultManager] removeItemAtURL:docsModelDir error:nil];
          // Copy entire model directory from app bundle to docs
          [[NSFileManager defaultManager] copyItemAtURL:appBundleModelDir toURL:docsModelDir error:&copyError];
          if (copyError) {
            NSLog(@"Failed to copy bundled model: %@", copyError.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
              reject(@"MODEL_ERROR", [NSString stringWithFormat:@"Failed to copy bundled model: %@", copyError.localizedDescription], copyError);
            });
            return;
          }
          NSLog(@"Successfully copied bundled model %@ to Documents", instanceId);
        } else {
          NSLog(@"Bundled model %@ already exists in Documents", instanceId);
        }
      } else {
        NSLog(@"Model %@ not found in app bundle, will download if needed", instanceId);
      }

      // Get model config
      NSError* configError;
      NSDictionary* modelConfig = [self getModelConfig:modelRecord error:&configError];

      if (configError || !modelConfig) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"MODEL_ERROR", @"Failed to get model config", configError);
        });
        return;
      }

      // Update model properties - with null checks
      NSString* modelLib = modelRecord[@"model_lib"];

      if (!modelLib) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"MODEL_ERROR", @"Invalid model config - missing required fields", nil);
        });
        return;
      }

      // Set model path to just use Documents directory and modelId
      NSString* modelId = modelRecord[@"model_id"];
      self.modelPath = modelId;
      self.modelLib = modelLib;

      // Initialize engine with model
      NSURL* modelLocalURL = [self.bundleURL URLByAppendingPathComponent:self.modelPath];

      if (!modelLocalURL) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"MODEL_ERROR", @"Failed to construct model path", nil);
        });
        return;
      }
      NSString* modelLocalPath = [modelLocalURL path];

      [self.engine reloadWithModelPath:modelLocalPath modelLib:self.modelLib];

      dispatch_async(dispatch_get_main_queue(), ^{
        resolve([NSString stringWithFormat:@"Model prepared: %@", instanceId]);
      });

    } @catch (NSException* exception) {
      dispatch_async(dispatch_get_main_queue(), ^{
        reject(@"MODEL_ERROR", exception.reason, nil);
      });
    }
  });
}

- (NSDictionary*)getModelConfig:(NSDictionary*)modelRecord error:(NSError**)error {
  [self downloadModelConfig:modelRecord error:error];
  if (*error != nil) {
    return nil;
  }

  NSString* modelId = modelRecord[@"model_id"];

  // Use the same path construction as downloadModelConfig
  NSURL* modelDirURL = [self.bundleURL URLByAppendingPathComponent:modelId];
  NSURL* modelConfigURL = [modelDirURL URLByAppendingPathComponent:@"mlc-chat-config.json"];

  NSData* jsonData = [NSData dataWithContentsOfURL:modelConfigURL];
  if (!jsonData) {
    if (error) {
      *error = [NSError errorWithDomain:@"AiModule" code:1 userInfo:@{NSLocalizedDescriptionKey : @"Requested model config not found"}];
    }
    return nil;
  }

  return [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:error];
}

- (void)downloadModelConfig:(NSDictionary*)modelRecord error:(NSError**)error {
  NSString* modelId = modelRecord[@"model_id"];

  if (!modelId) {
    if (error) {
      *error = [NSError errorWithDomain:@"AiModule" code:3 userInfo:@{NSLocalizedDescriptionKey : @"Missing model_id"}];
    }
    return;
  }

  // Check if config already exists
  NSURL* modelDirURL = [self.bundleURL URLByAppendingPathComponent:modelId];
  NSURL* modelConfigURL = [modelDirURL URLByAppendingPathComponent:@"mlc-chat-config.json"];
  NSURL* ndarrayCacheURL = [modelDirURL URLByAppendingPathComponent:@"ndarray-cache.json"];

  // If config files already exist (either copied from bundle or downloaded), skip download
  if ([[NSFileManager defaultManager] fileExistsAtPath:[modelConfigURL path]] && 
      [[NSFileManager defaultManager] fileExistsAtPath:[ndarrayCacheURL path]]) {
    return; // Files already exist, no need to download
  }

  // For missing files, we need model_url to download
  NSString* modelUrl = modelRecord[@"model_url"];
  if (!modelUrl) {
    if (error) {
      *error = [NSError errorWithDomain:@"AiModule" code:3 userInfo:@{NSLocalizedDescriptionKey : @"Missing model_url for download"}];
    }
    return;
  }

  if (!modelDirURL || !modelConfigURL) {
    if (error) {
      *error = [NSError errorWithDomain:@"AiModule" code:4 userInfo:@{NSLocalizedDescriptionKey : @"Failed to construct config URLs"}];
    }
    return;
  }

  // Create model directory if it doesn't exist
  NSError* dirError;
  [[NSFileManager defaultManager] createDirectoryAtPath:[modelDirURL path] withIntermediateDirectories:YES attributes:nil error:&dirError];
  if (dirError) {
    *error = dirError;
    return;
  }

  // Download and save model config if it doesn't exist
  if (![[NSFileManager defaultManager] fileExistsAtPath:[modelConfigURL path]]) {
    [self downloadAndSaveConfig:modelUrl configName:@"mlc-chat-config.json" toURL:modelConfigURL error:error];
    if (*error != nil)
      return;
  }

  // Download and save ndarray-cache if it doesn't exist
  if (![[NSFileManager defaultManager] fileExistsAtPath:[ndarrayCacheURL path]]) {
    [self downloadAndSaveConfig:modelUrl configName:@"ndarray-cache.json" toURL:ndarrayCacheURL error:error];
    if (*error != nil)
      return;
  }

  // Read and parse ndarray cache
  NSData* ndarrayCacheData = [NSData dataWithContentsOfURL:ndarrayCacheURL];
  if (!ndarrayCacheData) {
    if (error) {
      *error = [NSError errorWithDomain:@"AiModule" code:2 userInfo:@{NSLocalizedDescriptionKey : @"Failed to read ndarray cache"}];
    }
    return;
  }

  NSError* ndarrayCacheJsonError;
  NSDictionary* ndarrayCache = [NSJSONSerialization JSONObjectWithData:ndarrayCacheData options:0 error:&ndarrayCacheJsonError];
  if (ndarrayCacheJsonError) {
    *error = ndarrayCacheJsonError;
    return;
  }

  // Download parameter files from ndarray cache
  NSArray* records = ndarrayCache[@"records"];
  if ([records isKindOfClass:[NSArray class]]) {
    for (NSDictionary* record in records) {
      NSString* dataPath = record[@"dataPath"];
      if (dataPath) {
        NSURL* fileURL = [modelDirURL URLByAppendingPathComponent:dataPath];
        if (![[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
          [self downloadModelFile:modelUrl filename:dataPath toURL:fileURL error:error];
          if (*error != nil)
            return;
        }
      }
    }
  }

  // Read and parse model config
  NSData* modelConfigData = [NSData dataWithContentsOfURL:modelConfigURL];
  if (!modelConfigData) {
    if (error) {
      *error = [NSError errorWithDomain:@"AiModule" code:2 userInfo:@{NSLocalizedDescriptionKey : @"Failed to read model config"}];
    }
    return;
  }

  NSError* modelConfigJsonError;
  NSDictionary* modelConfig = [NSJSONSerialization JSONObjectWithData:modelConfigData options:0 error:&modelConfigJsonError];
  if (modelConfigJsonError) {
    *error = modelConfigJsonError;
    return;
  }

  // Download tokenizer files
  NSArray* tokenizerFiles = modelConfig[@"tokenizer_files"];
  for (NSString* filename in tokenizerFiles) {
    NSURL* fileURL = [modelDirURL URLByAppendingPathComponent:filename];
    if (![[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
      [self downloadModelFile:modelUrl filename:filename toURL:fileURL error:error];
      if (*error != nil)
        return;
    }
  }

  // Download model file
  NSString* modelPath = modelConfig[@"model_path"];
  if (modelPath) {
    NSURL* fileURL = [modelDirURL URLByAppendingPathComponent:modelPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
      [self downloadModelFile:modelUrl filename:modelPath toURL:fileURL error:error];
      if (*error != nil)
        return;
    }
  }
}

- (void)downloadAndSaveConfig:(NSString*)modelUrl configName:(NSString*)configName toURL:(NSURL*)destURL error:(NSError**)error {
  NSString* urlString = [NSString stringWithFormat:@"%@/resolve/main/%@", modelUrl, configName];
  NSURL* url = [NSURL URLWithString:urlString];

  NSData* configData = [NSData dataWithContentsOfURL:url];
  if (!configData) {
    if (error) {
      *error = [NSError errorWithDomain:@"AiModule"
                                   code:2
                               userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to download %@", configName]}];
    }
    return;
  }

  if (![configData writeToURL:destURL atomically:YES]) {
    if (error) {
      *error = [NSError errorWithDomain:@"AiModule"
                                   code:6
                               userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to write %@", configName]}];
    }
    return;
  }
}

- (void)downloadModelFile:(NSString*)modelUrl filename:(NSString*)filename toURL:(NSURL*)destURL error:(NSError**)error {
  NSLog(@"🔄 Downloading model file: %@ from %@", filename, modelUrl);
  NSString* urlString = [NSString stringWithFormat:@"%@/resolve/main/%@", modelUrl, filename];
  NSURL* url = [NSURL URLWithString:urlString];

  NSData* fileData = [NSData dataWithContentsOfURL:url];
  if (!fileData) {
    if (error) {
      *error = [NSError errorWithDomain:@"AiModule"
                                   code:2
                               userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to download %@", filename]}];
    }
    return;
  }

  if (![fileData writeToURL:destURL atomically:YES]) {
    if (error) {
      *error = [NSError errorWithDomain:@"AiModule"
                                   code:6
                               userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Failed to write %@", filename]}];
    }
    return;
  }
}

RCT_EXPORT_METHOD(downloadModel : (NSString*)instanceId resolve : (RCTPromiseResolveBlock)resolve reject : (RCTPromiseRejectBlock)reject) {
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    @try {
      // Read app config
      NSURL* configURL = [self.bundleURL URLByAppendingPathComponent:@"mlc-app-config.json"];
      NSData* jsonData = [NSData dataWithContentsOfURL:configURL];

      if (!jsonData) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"MODEL_ERROR", @"Failed to read app config", nil);
        });
        return;
      }

      NSError* error;
      NSDictionary* appConfig = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];

      if (error) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"MODEL_ERROR", @"Failed to parse app config", error);
        });
        return;
      }

      // Find model record
      NSArray* modelList = appConfig[@"model_list"];
      NSDictionary* modelRecord = nil;

      for (NSDictionary* model in modelList) {
        if ([model[@"model_id"] isEqualToString:instanceId]) {
          modelRecord = model;
          break;
        }
      }

      if (!modelRecord) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"MODEL_ERROR", @"There's no record for requested model", nil);
        });
        return;
      }

      // Send download start event
      if (self->hasListeners) {
        [self sendEventWithName:@"onDownloadStart" body:nil];
      }

      // Get model config and download files
      NSError* configError;
      NSDictionary* modelConfig = [self getModelConfig:modelRecord error:&configError];

      if (configError || !modelConfig) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"MODEL_ERROR", @"Failed to get model config", configError);
        });
        return;
      }

      // Calculate total files to download
      NSInteger totalFiles = 0;
      __block NSInteger downloadedFiles = 0;

      // Count files from ndarray cache
      NSURL* modelDirURL = [self.bundleURL URLByAppendingPathComponent:modelRecord[@"model_id"]];
      NSURL* ndarrayCacheURL = [modelDirURL URLByAppendingPathComponent:@"ndarray-cache.json"];
      NSData* ndarrayCacheData = [NSData dataWithContentsOfURL:ndarrayCacheURL];
      if (ndarrayCacheData) {
        NSDictionary* ndarrayCache = [NSJSONSerialization JSONObjectWithData:ndarrayCacheData options:0 error:nil];
        NSArray* records = ndarrayCache[@"records"];
        if ([records isKindOfClass:[NSArray class]]) {
          totalFiles += records.count;
        }
      }

      // Count tokenizer files
      NSArray* tokenizerFiles = modelConfig[@"tokenizer_files"];
      if ([tokenizerFiles isKindOfClass:[NSArray class]]) {
        totalFiles += tokenizerFiles.count;
      }

      // Add model file
      if (modelConfig[@"model_path"]) {
        totalFiles += 1;
      }

      // Add config files
      totalFiles += 2; // mlc-chat-config.json and ndarray-cache.json

      // Send progress updates during download
      void (^updateProgress)(void) = ^{
        downloadedFiles++;
        if (self->hasListeners) {
          double percentage = (double)downloadedFiles / totalFiles * 100.0;
          [self sendEventWithName:@"onDownloadProgress" body:@{@"percentage" : @(percentage)}];
        }
      };

      // Download config files
      [self downloadAndSaveConfig:modelRecord[@"model_url"]
                       configName:@"mlc-chat-config.json"
                            toURL:[modelDirURL URLByAppendingPathComponent:@"mlc-chat-config.json"]
                            error:&error];
      if (error) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"MODEL_ERROR", @"Failed to download config files", error);
        });
        return;
      }
      updateProgress();

      [self downloadAndSaveConfig:modelRecord[@"model_url"] configName:@"ndarray-cache.json" toURL:ndarrayCacheURL error:&error];
      if (error) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"MODEL_ERROR", @"Failed to download config files", error);
        });
        return;
      }
      updateProgress();

      // Download parameter files
      NSDictionary* ndarrayCache = [NSJSONSerialization JSONObjectWithData:ndarrayCacheData options:0 error:nil];
      NSArray* records = ndarrayCache[@"records"];
      if ([records isKindOfClass:[NSArray class]]) {
        for (NSDictionary* record in records) {
          NSString* dataPath = record[@"dataPath"];
          if (dataPath) {
            NSURL* fileURL = [modelDirURL URLByAppendingPathComponent:dataPath];
            [self downloadModelFile:modelRecord[@"model_url"] filename:dataPath toURL:fileURL error:&error];
            if (error) {
              dispatch_async(dispatch_get_main_queue(), ^{
                reject(@"MODEL_ERROR", @"Failed to download parameter files", error);
              });
              return;
            }
            updateProgress();
          }
        }
      }

      // Download tokenizer files
      for (NSString* filename in tokenizerFiles) {
        NSURL* fileURL = [modelDirURL URLByAppendingPathComponent:filename];
        [self downloadModelFile:modelRecord[@"model_url"] filename:filename toURL:fileURL error:&error];
        if (error) {
          dispatch_async(dispatch_get_main_queue(), ^{
            reject(@"MODEL_ERROR", @"Failed to download tokenizer files", error);
          });
          return;
        }
        updateProgress();
      }

      // Download model file
      NSString* modelPath = modelConfig[@"model_path"];
      if (modelPath) {
        NSURL* fileURL = [modelDirURL URLByAppendingPathComponent:modelPath];
        [self downloadModelFile:modelRecord[@"model_url"] filename:modelPath toURL:fileURL error:&error];
        if (error) {
          dispatch_async(dispatch_get_main_queue(), ^{
            reject(@"MODEL_ERROR", @"Failed to download model file", error);
          });
          return;
        }
        updateProgress();
      }

      // Send download complete event
      if (self->hasListeners) {
        [self sendEventWithName:@"onDownloadComplete" body:nil];
      }

      dispatch_async(dispatch_get_main_queue(), ^{
        resolve([NSString stringWithFormat:@"Model downloaded: %@", instanceId]);
      });

    } @catch (NSException* exception) {
      if (self->hasListeners) {
        [self sendEventWithName:@"onDownloadError" body:@{@"message" : exception.reason ?: @"Unknown error"}];
      }
      dispatch_async(dispatch_get_main_queue(), ^{
        reject(@"MODEL_ERROR", exception.reason, nil);
      });
    }
  });
}

RCT_EXPORT_METHOD(deleteAllModels : (RCTPromiseResolveBlock)resolve reject : (RCTPromiseRejectBlock)reject) {
  NSLog(@"🗑️ [Ai] Deleting all downloaded models");
  
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    @try {
      // Read app config to get list of models
      NSURL* configURL = [self.bundleURL URLByAppendingPathComponent:@"mlc-app-config.json"];
      NSData* jsonData = [NSData dataWithContentsOfURL:configURL];

      if (!jsonData) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"DELETE_ERROR", @"Failed to read app config", nil);
        });
        return;
      }

      NSError* error;
      NSDictionary* appConfig = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&error];

      if (error) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"DELETE_ERROR", @"Failed to parse app config", error);
        });
        return;
      }

      NSArray* modelList = appConfig[@"model_list"];
      if (![modelList isKindOfClass:[NSArray class]]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          reject(@"DELETE_ERROR", @"Invalid model list in config", nil);
        });
        return;
      }

      NSMutableArray* deletedModels = [NSMutableArray array];
      NSMutableArray* errors = [NSMutableArray array];

      // Delete each model directory
      for (NSDictionary* model in modelList) {
        NSString* modelId = model[@"model_id"];
        if (modelId) {
          NSURL* modelDirURL = [self.bundleURL URLByAppendingPathComponent:modelId];
          
          if ([[NSFileManager defaultManager] fileExistsAtPath:[modelDirURL path]]) {
            NSError* deleteError;
            if ([[NSFileManager defaultManager] removeItemAtURL:modelDirURL error:&deleteError]) {
              [deletedModels addObject:modelId];
              NSLog(@"✅ [Ai] Deleted model: %@", modelId);
            } else {
              [errors addObject:[NSString stringWithFormat:@"Failed to delete %@: %@", modelId, deleteError.localizedDescription]];
              NSLog(@"❌ [Ai] Failed to delete model %@: %@", modelId, deleteError.localizedDescription);
            }
          } else {
            NSLog(@"ℹ️ [Ai] Model %@ was not downloaded, skipping", modelId);
          }
        }
      }

      dispatch_async(dispatch_get_main_queue(), ^{
        if (errors.count > 0) {
          NSString* errorMessage = [errors componentsJoinedByString:@"; "];
          reject(@"DELETE_ERROR", errorMessage, nil);
        } else {
          NSString* resultMessage = [NSString stringWithFormat:@"Successfully deleted %lu models", (unsigned long)deletedModels.count];
          NSLog(@"✅ [Ai] %@", resultMessage);
          resolve(resultMessage);
        }
      });

    } @catch (NSException* exception) {
      dispatch_async(dispatch_get_main_queue(), ^{
        reject(@"DELETE_ERROR", exception.reason, nil);
      });
    }
  });
}

RCT_EXPORT_METHOD(cancelInference : (RCTPromiseResolveBlock)resolve reject : (RCTPromiseRejectBlock)reject) {
  NSLog(@"🛑 [Ai] Cancelling inference");
  
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    @try {
      if (self.engine) {
        @try {
          [self.engine abort:@""];
        } @catch (NSException* abortException) {
          NSLog(@"🟡 [Ai] Abort method failed: %@", abortException.reason);
        }
        
        NSLog(@"✅ [Ai] Inference cancelled successfully");
        
        dispatch_async(dispatch_get_main_queue(), ^{
          resolve(@"Inference cancelled");
        });
      } else {
        dispatch_async(dispatch_get_main_queue(), ^{
          resolve(@"No active inference to cancel");
        });
      }
    } @catch (NSException* exception) {
      dispatch_async(dispatch_get_main_queue(), ^{
        reject(@"CANCEL_ERROR", exception.reason, nil);
      });
    }
  });
}

// Comprehensive model download verification
- (BOOL)isModelCompletelyDownloaded:(NSString*)modelId {
  if (!modelId) {
    return NO;
  }

  NSURL* modelDirURL = [_bundleURL URLByAppendingPathComponent:modelId];
  
  // Check if model directory exists
  if (![[NSFileManager defaultManager] fileExistsAtPath:[modelDirURL path]]) {
    return NO;
  }

  @try {
    // 1. Check essential config files
    NSArray* essentialFiles = @[@"mlc-chat-config.json", @"ndarray-cache.json"];
    for (NSString* filename in essentialFiles) {
      NSURL* fileURL = [modelDirURL URLByAppendingPathComponent:filename];
      if (![[NSFileManager defaultManager] fileExistsAtPath:[fileURL path]]) {
        NSLog(@"❌ [Download Verification] Missing essential file: %@ for model: %@", filename, modelId);
        return NO;
      }
    }

    // 2. Parse ndarray-cache.json to get expected weight files
    NSURL* ndarrayCacheURL = [modelDirURL URLByAppendingPathComponent:@"ndarray-cache.json"];
    NSData* ndarrayData = [NSData dataWithContentsOfURL:ndarrayCacheURL];
    if (!ndarrayData) {
      NSLog(@"❌ [Download Verification] Cannot read ndarray-cache.json for model: %@", modelId);
      return NO;
    }

    NSError* jsonError;
    NSDictionary* ndarrayCache = [NSJSONSerialization JSONObjectWithData:ndarrayData options:0 error:&jsonError];
    if (jsonError || ![ndarrayCache isKindOfClass:[NSDictionary class]]) {
      NSLog(@"❌ [Download Verification] Cannot parse ndarray-cache.json for model: %@: %@", modelId, jsonError.localizedDescription);
      return NO;
    }

    // 3. Verify all weight shard files
    NSArray* records = ndarrayCache[@"records"];
    if ([records isKindOfClass:[NSArray class]]) {
      NSMutableSet* expectedFiles = [NSMutableSet set];
      
      for (NSDictionary* record in records) {
        if ([record isKindOfClass:[NSDictionary class]]) {
          NSString* dataPath = record[@"data_path"];
          if ([dataPath isKindOfClass:[NSString class]]) {
            [expectedFiles addObject:dataPath];
          }
        }
      }

      // Check if all expected weight files exist
      for (NSString* expectedFile in expectedFiles) {
        NSURL* weightFileURL = [modelDirURL URLByAppendingPathComponent:expectedFile];
        if (![[NSFileManager defaultManager] fileExistsAtPath:[weightFileURL path]]) {
          NSLog(@"❌ [Download Verification] Missing weight file: %@ for model: %@", expectedFile, modelId);
          return NO;
        }
        
        // Verify file is not empty (basic corruption check)
        NSError* attributesError;
        NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[weightFileURL path] error:&attributesError];
        if (attributesError || [attributes[NSFileSize] longLongValue] == 0) {
          NSLog(@"❌ [Download Verification] Weight file is empty or unreadable: %@ for model: %@", expectedFile, modelId);
          return NO;
        }
      }
    }

    // 4. Check tokenizer files
    NSURL* configURL = [modelDirURL URLByAppendingPathComponent:@"mlc-chat-config.json"];
    NSData* configData = [NSData dataWithContentsOfURL:configURL];
    if (configData) {
      NSError* configJsonError;
      NSDictionary* config = [NSJSONSerialization JSONObjectWithData:configData options:0 error:&configJsonError];
      if (!configJsonError && [config isKindOfClass:[NSDictionary class]]) {
        NSArray* tokenizerFiles = config[@"tokenizer_files"];
        if ([tokenizerFiles isKindOfClass:[NSArray class]]) {
          for (NSString* tokenizerFile in tokenizerFiles) {
            if ([tokenizerFile isKindOfClass:[NSString class]]) {
              NSURL* tokenizerURL = [modelDirURL URLByAppendingPathComponent:tokenizerFile];
              if (![[NSFileManager defaultManager] fileExistsAtPath:[tokenizerURL path]]) {
                NSLog(@"❌ [Download Verification] Missing tokenizer file: %@ for model: %@", tokenizerFile, modelId);
                return NO;
              }
            }
          }
        }
      }
    }

    // 5. Additional integrity checks for critical files
    // Check if config files are valid JSON and not corrupted
    NSArray* criticalJsonFiles = @[@"mlc-chat-config.json", @"ndarray-cache.json"];
    for (NSString* jsonFile in criticalJsonFiles) {
      NSURL* jsonURL = [modelDirURL URLByAppendingPathComponent:jsonFile];
      NSData* jsonData = [NSData dataWithContentsOfURL:jsonURL];
      if (jsonData) {
        NSError* parseError;
        id jsonObject = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&parseError];
        if (parseError || !jsonObject) {
          NSLog(@"❌ [Download Verification] Corrupted JSON file: %@ for model: %@", jsonFile, modelId);
          return NO;
        }
      }
    }

    NSLog(@"✅ [Download Verification] Model %@ is completely downloaded", modelId);
    return YES;
    
  } @catch (NSException* exception) {
    NSLog(@"❌ [Download Verification] Exception during verification for model: %@: %@", modelId, exception.reason);
    return NO;
  }
}

// Don't compile this code when we build for the old architecture.
#ifdef RCT_NEW_ARCH_ENABLED
- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:(const facebook::react::ObjCTurboModule::InitParams&)params {
  return std::make_shared<facebook::react::NativeAiSpecJSI>(params);
}
#endif

@end
