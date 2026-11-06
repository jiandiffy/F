import { createProvider } from '@earendil-works/pi-ai';
import { deepseekProvider } from '@earendil-works/pi-ai/providers/deepseek';
import { openaiCodexProvider } from '@earendil-works/pi-ai/providers/openai-codex';
import { providerProfiles } from '../../../auth/providers.mjs';

export default async function(pi) {
  const profiles = await providerProfiles();
  for (const [name, original] of [['deepseek', deepseekProvider()], ['openai', openaiCodexProvider()]] as const) {
    const id = profiles.find(profile => profile.name === name)!.provider;
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
