export interface LaunchConfig {
  appId: string;
  namespace: number;
  message: string;
  name: string;
}

// Verified against Vizio's official catalog on 2026-08-13. Keeping the quick
// launch table in the app removes a runtime cloud lookup from normal control.
export const BUILTIN_LAUNCH_CONFIGS: Record<string, LaunchConfig> = {
  hulu: { appId: '3', namespace: 2, message: '', name: 'Hulu' },
  youtube: { appId: '1', namespace: 5, message: '', name: 'YouTube' },
  netflix: { appId: '1', namespace: 3, message: '', name: 'Netflix' },
};

export class AppCatalog {
  async resolve(nameOrId: string): Promise<LaunchConfig> {
    const query = nameOrId.trim().toLowerCase();
    if (!query) throw new Error('Enter an app name.');
    const exact = BUILTIN_LAUNCH_CONFIGS[query];
    if (exact) return structuredClone(exact);
    const partial = Object.values(BUILTIN_LAUNCH_CONFIGS).find((app) => app.name.toLowerCase().includes(query));
    if (partial) return structuredClone(partial);
    throw new Error(`The local quick launcher does not contain “${nameOrId}”. Use SmartCast Home to open it manually.`);
  }
}
