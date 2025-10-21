"use strict";

Object.defineProperty(exports, "__esModule", {
  value: true
});
exports.doStream = exports.doGenerate = exports.default = void 0;
exports.downloadModel = downloadModel;
exports.getModel = getModel;
exports.getModels = getModels;
exports.prepareModel = prepareModel;
var _reactNative = require("react-native");
require("./polyfills");
var _webStreamsPolyfill = require("web-streams-polyfill");
const LINKING_ERROR = `The package 'react-native-ai' doesn't seem to be linked. Make sure: \n\n` + _reactNative.Platform.select({
  ios: "- You have run 'pod install'\n",
  default: ''
}) + '- You rebuilt the app after installing the package\n' + '- You are not using Expo Go\n';

// @ts-expect-error
const isTurboModuleEnabled = global.__turboModuleProxy != null;
const AiModule = isTurboModuleEnabled ? require('./NativeAi').default : _reactNative.NativeModules.Ai;
const Ai = AiModule ? AiModule : new Proxy({}, {
  get() {
    throw new Error(LINKING_ERROR);
  }
});
var _default = exports.default = Ai;
class AiModel {
  specificationVersion = 'v1';
  defaultObjectGenerationMode = 'json';
  provider = 'gemini-nano';
  constructor(modelId, options = {}) {
    this.modelId = modelId;
    this.options = options;
    console.debug('init:', this.modelId);
  }
  async getModel() {
    this.model = await Ai.getModel(this.modelId);
    return this.model;
  }
  async doGenerate(options) {
    const model = await this.getModel();
    const messages = options.prompt;
    const extractedMessages = messages.map(message => {
      let content = '';
      if (Array.isArray(message.content)) {
        content = message.content.map(messageContent => messageContent.type === 'text' ? messageContent.text : messageContent).join('');
      }
      return {
        role: message.role,
        content: content
      };
    });
    let text = '';
    if (messages.length > 0) {
      text = await Ai.doGenerate(model.modelId, extractedMessages);
    }
    return {
      text,
      finishReason: 'stop',
      usage: {
        promptTokens: 0,
        completionTokens: 0
      },
      rawCall: {
        rawPrompt: options,
        rawSettings: {}
      }
    };
  }
  stream = null;
  controller = null;
  streamId = null;
  chatUpdateListener = null;
  chatCompleteListener = null;
  chatErrorListener = null;
  isStreamClosed = false;
  doStream = async options => {
    // Reset stream state
    this.isStreamClosed = false;
    const messages = options.prompt;
    const extractedMessages = messages.map(message => {
      let content = '';
      if (Array.isArray(message.content)) {
        content = message.content.map(messageContent => messageContent.type === 'text' ? messageContent.text : messageContent).join('');
      }
      return {
        role: message.role,
        content: content
      };
    });
    const model = await this.getModel();
    const stream = new _webStreamsPolyfill.ReadableStream({
      start: controller => {
        this.controller = controller;
        const eventEmitter = new _reactNative.NativeEventEmitter(_reactNative.NativeModules.Ai);
        this.chatCompleteListener = eventEmitter.addListener('onChatComplete', () => {
          try {
            if (!this.isStreamClosed && this.controller) {
              this.controller.enqueue({
                type: 'finish',
                finishReason: 'stop',
                usage: {
                  promptTokens: 0,
                  completionTokens: 0
                }
              });
              this.isStreamClosed = true;
              this.controller.close();
            }
          } catch (error) {
            console.error('🔴 [Stream] Error in complete handler:', error);
          }
        });
        this.chatErrorListener = eventEmitter.addListener('onChatUpdate', data => {
          console.log('🟢 [Stream] Update data:', JSON.stringify(data, null, 2));
          try {
            if (!this.isStreamClosed && this.controller) {
              if (data.error) {
                this.controller.enqueue({
                  type: 'error',
                  error: data.error
                });
                this.isStreamClosed = true;
                this.controller.close();
              } else {
                this.controller.enqueue({
                  type: 'text-delta',
                  textDelta: data.content || ''
                });
              }
            } else {
              console.log('🟡 [Stream] Cannot update - stream closed or no controller');
            }
          } catch (error) {
            console.error('🔴 [Stream] Error in update handler:', error);
          }
        });
        if (!model) {
          console.error('🔴 [Stream] Model not initialized');
          throw new Error('Model not initialized');
        }
        console.log('🔵 [Stream] Starting native stream with model:', model.modelId);
        Ai.doStream(model.modelId, extractedMessages);
      },
      cancel: () => {
        console.log('🟡 [Stream] Stream cancelled, cleaning up');
        this.isStreamClosed = true;
        if (this.chatUpdateListener) {
          console.log('🟡 [Stream] Removing chat update listener');
          this.chatUpdateListener.remove();
        }
        if (this.chatCompleteListener) {
          console.log('🟡 [Stream] Removing chat complete listener');
          this.chatCompleteListener.remove();
        }
        if (this.chatErrorListener) {
          console.log('🟡 [Stream] Removing chat error listener');
          this.chatErrorListener.remove();
        }
      },
      pull: _controller => {
        console.log('🔵 [Stream] Pull called');
      }
    });
    return {
      stream,
      rawCall: {
        rawPrompt: options.prompt,
        rawSettings: this.options
      }
    };
  };

  // Add other methods here as needed
}
function getModel(modelId, options = {}) {
  return new AiModel(modelId, options);
}
async function getModels() {
  return Ai.getModels();
}
async function downloadModel(modelId, callbacks) {
  const eventEmitter = new _reactNative.NativeEventEmitter(_reactNative.NativeModules.Ai);
  const downloadStartListener = eventEmitter.addListener('onDownloadStart', () => {
    console.log('🔵 [Download] Started downloading model:', modelId);
    callbacks?.onStart?.();
  });
  const downloadProgressListener = eventEmitter.addListener('onDownloadProgress', progress => {
    console.log('🟢 [Download] Progress:', progress.percentage.toFixed(2) + '%');
    callbacks?.onProgress?.(progress);
  });
  const downloadCompleteListener = eventEmitter.addListener('onDownloadComplete', () => {
    console.log('✅ [Download] Completed downloading model:', modelId);
    callbacks?.onComplete?.();
    // Cleanup listeners
    downloadStartListener.remove();
    downloadProgressListener.remove();
    downloadCompleteListener.remove();
    downloadErrorListener.remove();
  });
  const downloadErrorListener = eventEmitter.addListener('onDownloadError', error => {
    console.error('🔴 [Download] Error downloading model:', error);
    callbacks?.onError?.(new Error(error.message || 'Unknown download error'));
    // Cleanup listeners
    downloadStartListener.remove();
    downloadProgressListener.remove();
    downloadCompleteListener.remove();
    downloadErrorListener.remove();
  });
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
async function prepareModel(modelId) {
  return Ai.prepareModel(modelId);
}
const {
  doGenerate,
  doStream
} = Ai;
exports.doStream = doStream;
exports.doGenerate = doGenerate;
//# sourceMappingURL=index.js.map