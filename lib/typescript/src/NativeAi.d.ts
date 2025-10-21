import type { TurboModule } from 'react-native';
import type { AiModelSettings, Message } from './index';
export interface Spec extends TurboModule {
    getModel(name: string): Promise<string>;
    getModels(): Promise<AiModelSettings[]>;
    doGenerate(instanceId: string, messages: Message[]): Promise<string>;
    doStream(instanceId: string, messages: Message[]): Promise<string>;
    downloadModel(instanceId: string): Promise<string>;
    prepareModel(instanceId: string): Promise<string>;
}
declare const _default: Spec;
export default _default;
//# sourceMappingURL=NativeAi.d.ts.map