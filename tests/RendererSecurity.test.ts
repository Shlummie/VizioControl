import { describe, expect, it } from 'vitest';
import { isAllowedRendererNavigation, selectDevelopmentRendererUrl } from '../electron/rendererSecurity';

describe('privileged renderer navigation boundary', () => {
  it('never honors a development URL in a packaged build', () => {
    expect(selectDevelopmentRendererUrl(true, 'http://127.0.0.1:5173/')).toBeNull();
    expect(selectDevelopmentRendererUrl(true, 'https://attacker.example/')).toBeNull();
  });

  it('accepts only the exact loopback Vite URL in development', () => {
    expect(selectDevelopmentRendererUrl(false, 'http://127.0.0.1:5173/')).toBe('http://127.0.0.1:5173/');
    expect(selectDevelopmentRendererUrl(false, 'http://localhost:5173/')).toBeNull();
    expect(selectDevelopmentRendererUrl(false, 'http://127.0.0.1:5173/attacker')).toBeNull();
    expect(selectDevelopmentRendererUrl(false, 'https://127.0.0.1:5173/')).toBeNull();
  });

  it('blocks navigation away from the selected local renderer', () => {
    const packaged = 'file:///C:/TV%20Remote/resources/app.asar/dist/index.html';
    expect(isAllowedRendererNavigation(`${packaged}#settings`, packaged)).toBe(true);
    expect(isAllowedRendererNavigation('file:///C:/Windows/System32/index.html', packaged)).toBe(false);
    expect(isAllowedRendererNavigation('https://attacker.example/', packaged)).toBe(false);

    const development = 'http://127.0.0.1:5173/';
    expect(isAllowedRendererNavigation('http://127.0.0.1:5173/settings', development)).toBe(true);
    expect(isAllowedRendererNavigation('http://127.0.0.1:5174/', development)).toBe(false);
    expect(isAllowedRendererNavigation('https://attacker.example/', development)).toBe(false);
  });
});
