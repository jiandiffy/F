import { createProvider } from '@earendil-works/pi-ai';
import { deepseekProvider } from '@earendil-works/pi-ai/providers/deepseek';
import { openaiCodexProvider } from '@earendil-works/pi-ai/providers/openai-codex';

export default function(pi) {
  for (const [id, original] of [['dp', deepseekProvider()], ['gpt', openaiCodexProvider()]] as const) {
    pi.registerProvider(createProvider({
      id, name: id, baseUrl: original.baseUrl, headers: original.headers,
      auth: original.auth,
      models: original.getModels().map(model => ({ ...model, provider: id })),
      api: {
        stream: (model, context, options) => original.stream(model, context, options),
        streamSimple: (model, context, options) => original.streamSimple(model, context, options),
      },
    }));
  }
}
