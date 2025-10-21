import { NativeEventEmitter, NativeModules, Platform, TurboModuleRegistry } from 'react-native';
import {
  type LanguageModelV1,
  type LanguageModelV1CallOptions,
  type LanguageModelV1CallWarning,
  type LanguageModelV1FinishReason,
  type LanguageModelV1FunctionToolCall,
  type LanguageModelV1StreamPart,
} from '@ai-sdk/provider';
import './polyfills';
import type { EmitterSubscription } from 'react-native';
import {
  ReadableStream,
  ReadableStreamDefaultController,
} from 'web-streams-polyfill';

const LINKING_ERROR =
  `The package 'react-native-ai' doesn't seem to be linked. Make sure: \n\n` +
  Platform.select({ ios: "- You have run 'pod install'\n", default: '' }) +
  '- You rebuilt the app after installing the package\n' +
  '- You are not using Expo Go\n';

const isTurboModuleEnabled = global.__turboModuleProxy != null;

const AiModule = isTurboModuleEnabled
  ? require('./NativeAi').default
  : NativeModules.Ai;

const Ai = AiModule
  ? AiModule
  : new Proxy(
      {},
      {
        get() {
          throw new Error(LINKING_ERROR);
        },
      }
    );

export default Ai;

export interface AiModelSettings extends Record<string, unknown> {
  model_id?: string;
  downloaded?: boolean;
}

export interface Model {
  modelId: string;
  modelLib: string;
}

export interface Message {
  role: 'assistant' | 'system' | 'tool' | 'user';
  content: string;
}

export interface DownloadProgress {
  percentage: number;
}

export interface ExtendedUsageMetrics {
  promptTokens: number;
  completionTokens: number;
  totalTokens?: number;
  // Performance metrics from MLC engine
  timeToFirstToken?: number;           // ttft_s
  prefillTokensPerSecond?: number;     // prefill_tokens_per_s  
  prefillTokens?: number;              // prefill_tokens
  jumpForwardTokens?: number;          // jump_forward_tokens
  endToEndLatency?: number;            // end_to_end_latency_s
  interTokenLatency?: number;          // inter_token_latency_s
  decodeTokensPerSecond?: number;      // decode_tokens_per_s
  decodeTokens?: number;               // decode_tokens
}

// Helper function to extract complete usage data from MLC response
function extractExtendedUsage(usageData: any): ExtendedUsageMetrics {
  const baseUsage: ExtendedUsageMetrics = {
    promptTokens: usageData?.prompt_tokens || 0,
    completionTokens: usageData?.completion_tokens || 0,
    totalTokens: usageData?.total_tokens || 0,
  };

  // Extract performance metrics from the 'extra' field
  if (usageData?.extra) {
    const extra = usageData.extra;
    
    const extendedUsage = {
      ...baseUsage,
      timeToFirstToken: extra.ttft_s,
      prefillTokensPerSecond: extra.prefill_tokens_per_s,
      prefillTokens: extra.prefill_tokens,
      jumpForwardTokens: extra.jump_forward_tokens,
      endToEndLatency: extra.end_to_end_latency_s,
      interTokenLatency: extra.inter_token_latency_s,
      decodeTokensPerSecond: extra.decode_tokens_per_s,
      decodeTokens: extra.decode_tokens,
    };
    
    return extendedUsage;
  }

  return baseUsage;
}

class AiModel implements LanguageModelV1 {
  readonly specificationVersion = 'v1';
  readonly defaultObjectGenerationMode = 'json';
  readonly provider = 'gemini-nano';
  public modelId: string;
  private options: AiModelSettings;

  constructor(modelId: string, options: AiModelSettings = {}) {
    this.modelId = modelId;
    this.options = options;

    console.debug('init:', this.modelId);
  }

  private model!: Model;
  async getModel() {
    this.model = await Ai.getModel(this.modelId);

    return this.model;
  }

  async doGenerate(options: LanguageModelV1CallOptions): Promise<{
    text?: string;
    toolCalls?: Array<LanguageModelV1FunctionToolCall>;
    finishReason: LanguageModelV1FinishReason;
    usage: ExtendedUsageMetrics;
    rawCall: {
      rawPrompt: unknown;
      rawSettings: Record<string, unknown>;
    };
  }> {
    const model = await this.getModel();
    const messages = options.prompt;
    const extractedMessages = messages.map((message): Message => {
      let content = '';

      if (Array.isArray(message.content)) {
        content = message.content
          .map((messageContent) =>
            messageContent.type === 'text'
              ? messageContent.text
              : messageContent
          )
          .join('');
      }

      return {
        role: message.role,
        content: content,
      };
    });

    // Extract LLM settings from options
    const settings = {
      temperature: options.temperature,
      maxTokens: options.maxTokens,
      topP: options.topP,
      frequencyPenalty: options.frequencyPenalty,
      presencePenalty: options.presencePenalty,
    };

    let text = '';
    let usage: ExtendedUsageMetrics = { promptTokens: 0, completionTokens: 0 };

    if (messages.length > 0) {
      const result = await Ai.doGenerate(model.modelId, extractedMessages, settings);
      
      // Handle both string response (legacy) and object response (new)
      if (typeof result === 'string') {
        text = result;
      } else if (typeof result === 'object' && result !== null) {
        text = result.text || '';
        if (result.usage) {
          usage = extractExtendedUsage(result.usage);
          console.log('🟢 Usage:', usage);
        }
      }
    }

    return {
      text,
      finishReason: 'stop',
      usage: usage,
      rawCall: {
        rawPrompt: options,
        rawSettings: {},
      },
    };
  }

  stream: ReadableStream<LanguageModelV1StreamPart> | null = null;
  controller: ReadableStreamDefaultController<LanguageModelV1StreamPart> | null =
    null;
  streamId: string | null = null;
  chatUpdateListener: EmitterSubscription | null = null;
  chatCompleteListener: EmitterSubscription | null = null;
  chatErrorListener: EmitterSubscription | null = null;
  isStreamClosed: boolean = false;

  // Add cleanup method to ensure proper event listener management
  private cleanupListeners() {
    if (this.chatUpdateListener) {
      this.chatUpdateListener.remove();
      this.chatUpdateListener = null;
    }
    if (this.chatCompleteListener) {
      this.chatCompleteListener.remove();
      this.chatCompleteListener = null;
    }
    if (this.chatErrorListener) {
      this.chatErrorListener.remove();
      this.chatErrorListener = null;
    }
  }

  public doStream = async (
    options: LanguageModelV1CallOptions
  ): Promise<{
    stream: ReadableStream<LanguageModelV1StreamPart>;
    rawCall: { rawPrompt: unknown; rawSettings: Record<string, unknown> };
    rawResponse?: { headers?: Record<string, string> };
    warnings?: LanguageModelV1CallWarning[];
  }> => {
    // Clean up any existing listeners before creating new ones
    this.cleanupListeners();
    
    // Reset stream state
    this.isStreamClosed = false;
    const messages = options.prompt;
    const extractedMessages = messages.map((message): Message => {
      let content = '';

      if (Array.isArray(message.content)) {
        content = message.content
          .map((messageContent) =>
            messageContent.type === 'text'
              ? messageContent.text
              : messageContent
          )
          .join('');
      }

      return {
        role: message.role,
        content: content,
      };
    });

    // Extract LLM settings from options
    const settings = {
      temperature: options.temperature,
      maxTokens: options.maxTokens,
      topP: options.topP,
      frequencyPenalty: options.frequencyPenalty,
      presencePenalty: options.presencePenalty,
    };

    const model = await this.getModel();

    const stream = new ReadableStream<LanguageModelV1StreamPart>({
      start: (controller) => {
        this.controller = controller;

        // In react-native-ai: Now works with both old and new architecture
const eventEmitter = new NativeEventEmitter(
  isTurboModuleEnabled ? TurboModuleRegistry.getEnforcing('Ai') : NativeModules.Ai
);
        this.chatCompleteListener = eventEmitter.addListener(
          'onChatComplete',
          (data) => {
            let usage: ExtendedUsageMetrics = { promptTokens: 0, completionTokens: 0 };

            if (data && data.usage) {
              usage = extractExtendedUsage(data.usage);
              console.log('🟢 Usage:', usage);
            }

            try {
              if (!this.isStreamClosed && this.controller) {
                if (data && data.cancelled) {
                  // Handle cancellation
                  console.log('🛑 [Stream] Stream was aborted');
                  this.controller.enqueue({
                    type: 'finish',
                    finishReason: 'other',
                    usage: { promptTokens: 0, completionTokens: 0 },
                  });
                } else {
                  // Handle normal completion
                  // Prepare standard usage object for ai library
                  const standardUsage = {
                    promptTokens: usage.promptTokens,
                    completionTokens: usage.completionTokens,
                  };

                  this.controller.enqueue({
                    type: 'finish',
                    finishReason: data.finishReason || 'stop',
                    usage: standardUsage,
                    // Include extended usage data as provider metadata
                    providerMetadata: {
                      mlc: {
                        extendedUsage: JSON.parse(JSON.stringify(usage)) as any,
                      },
                    },
                  });
                }
                
                this.isStreamClosed = true;
                this.controller.close();
                
                // Clean up listeners after completion
                this.cleanupListeners();
              }
            } catch (error) {
              console.error('🔴 [Stream] Error in complete handler:', error);
            }
          }
        );

        this.chatErrorListener = eventEmitter.addListener(
          'onChatUpdate',
          (data) => {
            try {
              if (!this.isStreamClosed && this.controller) {
                if (data.error) {
                  this.controller.enqueue({ type: 'error', error: data.error });
                  this.isStreamClosed = true;
                  this.controller.close();
                  
                  // Clean up listeners on error
                  this.cleanupListeners();
                } else {
                  this.controller.enqueue({
                    type: 'text-delta',
                    textDelta: data.content || '',
                  });
                }
              }
            } catch (error) {
              console.error('🔴 [Stream] Error in update handler:', error);
            }
          }
        );

        if (!model) {
          console.error('🔴 [Stream] Model not initialized');
          throw new Error('Model not initialized');
        }

        // Pass both messages and settings to native layer
        Ai.doStream(model.modelId, extractedMessages, settings);
      },
      cancel: () => {
        this.isStreamClosed = true;
        this.cleanupListeners();
      },
      pull: (_controller) => {
        // Required method for ReadableStream
      },
    });

    return {
      stream,
      rawCall: { rawPrompt: options.prompt, rawSettings: this.options },
    };
  };

  // Add other methods here as needed
}

type ModelOptions = {};

export function getModel(modelId: string, options: ModelOptions = {}): AiModel {
  return new AiModel(modelId, options);
}

export async function getModels(): Promise<AiModelSettings[]> {
  return Ai.getModels();
}

export async function downloadModel(
  modelId: string,
  callbacks?: {
    onStart?: () => void;
    onProgress?: (progress: DownloadProgress) => void;
    onComplete?: () => void;
    onError?: (error: Error) => void;
  }
): Promise<void> {
  const eventEmitter = new NativeEventEmitter(
    isTurboModuleEnabled
      ? TurboModuleRegistry.getEnforcing('Ai')
      : NativeModules.Ai,
  );

  const downloadStartListener = eventEmitter.addListener(
    'onDownloadStart',
    () => {
      console.log('🔵 [Download] Started downloading model:', modelId);
      callbacks?.onStart?.();
    }
  );

  const downloadProgressListener = eventEmitter.addListener(
    'onDownloadProgress',
    (progress: DownloadProgress) => {
      console.log(
        '🟢 [Download] Progress:',
        progress.percentage.toFixed(2) + '%'
      );
      callbacks?.onProgress?.(progress);
    }
  );

  const downloadCompleteListener = eventEmitter.addListener(
    'onDownloadComplete',
    () => {
      console.log('✅ [Download] Completed downloading model:', modelId);
      callbacks?.onComplete?.();
      // Cleanup listeners
      downloadStartListener.remove();
      downloadProgressListener.remove();
      downloadCompleteListener.remove();
      downloadErrorListener.remove();
    }
  );

  const downloadErrorListener = eventEmitter.addListener(
    'onDownloadError',
    (error) => {
      console.error('🔴 [Download] Error downloading model:', error);
      callbacks?.onError?.(
        new Error(error.message || 'Unknown download error')
      );
      // Cleanup listeners
      downloadStartListener.remove();
      downloadProgressListener.remove();
      downloadCompleteListener.remove();
      downloadErrorListener.remove();
    }
  );

  try {
    await Ai.downloadModel(modelId);
  } catch (error) {
    // Cleanup listeners in case of error
    downloadStartListener.remove();
    downloadProgressListener.remove();
    downloadCompleteListener.remove();
    downloadErrorListener.remove();
    throw error;
  }
}

export async function prepareModel(modelId: string) {
  return Ai.prepareModel(modelId);
}

export async function cancelInference(): Promise<void> {
  return Ai.cancelInference();
}

export async function deleteAllModels(): Promise<string> {
  return Ai.deleteAllModels();
}

const { doGenerate, doStream } = Ai;

export { doGenerate, doStream };
