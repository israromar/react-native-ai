import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

export interface Spec extends TurboModule {
  getModel(name: string): Promise<Object>;
  getModels(): Promise<Array<Object>>;
  doGenerate(
    instanceId: string,
    messages: Array<Object>,
    settings: Object,
  ): Promise<Object>;
  doStream(
    instanceId: string,
    messages: Array<Object>,
    settings: Object,
  ): Promise<string>;
  downloadModel(instanceId: string): Promise<void>;
  prepareModel(instanceId: string): Promise<void>;
  cancelInference(): Promise<void>;
  deleteAllModels(): Promise<string>;
  // Event emitter methods
  addListener(eventName: string): void;
  removeListeners(count: number): void;
}

export default TurboModuleRegistry.getEnforcing<Spec>('Ai');
