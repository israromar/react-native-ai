import { type LanguageModelV1, type LanguageModelV1CallOptions, type LanguageModelV1CallWarning, type LanguageModelV1FinishReason, type LanguageModelV1FunctionToolCall, type LanguageModelV1StreamPart } from '@ai-sdk/provider';
import './polyfills';
import type { EmitterSubscription } from 'react-native';
import { ReadableStream, ReadableStreamDefaultController } from 'web-streams-polyfill';
declare const Ai: any;
export default Ai;
export interface AiModelSettings extends Record<string, unknown> {
    model_id?: string;
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
declare class AiModel implements LanguageModelV1 {
    readonly specificationVersion = "v1";
    readonly defaultObjectGenerationMode = "json";
    readonly provider = "gemini-nano";
    modelId: string;
    private options;
    constructor(modelId: string, options?: AiModelSettings);
    private model;
    getModel(): Promise<Model>;
    doGenerate(options: LanguageModelV1CallOptions): Promise<{
        text?: string;
        toolCalls?: Array<LanguageModelV1FunctionToolCall>;
        finishReason: LanguageModelV1FinishReason;
        usage: {
            promptTokens: number;
            completionTokens: number;
        };
        rawCall: {
            rawPrompt: unknown;
            rawSettings: Record<string, unknown>;
        };
    }>;
    stream: ReadableStream<LanguageModelV1StreamPart> | null;
    controller: ReadableStreamDefaultController<LanguageModelV1StreamPart> | null;
    streamId: string | null;
    chatUpdateListener: EmitterSubscription | null;
    chatCompleteListener: EmitterSubscription | null;
    chatErrorListener: EmitterSubscription | null;
    isStreamClosed: boolean;
    doStream: (options: LanguageModelV1CallOptions) => Promise<{
        stream: ReadableStream<LanguageModelV1StreamPart>;
        rawCall: {
            rawPrompt: unknown;
            rawSettings: Record<string, unknown>;
        };
        rawResponse?: {
            headers?: Record<string, string>;
        };
        warnings?: LanguageModelV1CallWarning[];
    }>;
}
type ModelOptions = {};
export declare function getModel(modelId: string, options?: ModelOptions): AiModel;
export declare function getModels(): Promise<AiModelSettings[]>;
export declare function downloadModel(modelId: string, callbacks?: {
    onStart?: () => void;
    onProgress?: (progress: DownloadProgress) => void;
    onComplete?: () => void;
    onError?: (error: Error) => void;
}): Promise<void>;
export declare function prepareModel(modelId: string): Promise<any>;
export declare function cancelInference(): Promise<void>;
export declare function deleteAllModels(): Promise<string>;
declare const doGenerate: any, doStream: any;
export { doGenerate, doStream };
//# sourceMappingURL=index.d.ts.map