const DEVELOPMENT_RENDERER_URL = 'http://127.0.0.1:5173/';

export function selectDevelopmentRendererUrl(isPackaged: boolean, value: string | undefined) {
  if (isPackaged || !value) return null;
  try {
    const candidate = new URL(value);
    if (candidate.href !== DEVELOPMENT_RENDERER_URL) return null;
    return DEVELOPMENT_RENDERER_URL;
  } catch {
    return null;
  }
}

export function isAllowedRendererNavigation(value: string, selectedRendererUrl: string) {
  try {
    const candidate = new URL(value);
    const selected = new URL(selectedRendererUrl);
    if (selected.protocol === 'file:') {
      return candidate.protocol === 'file:'
        && candidate.host === selected.host
        && candidate.pathname === selected.pathname
        && candidate.search === selected.search;
    }
    return selected.href === DEVELOPMENT_RENDERER_URL && candidate.origin === selected.origin;
  } catch {
    return false;
  }
}
