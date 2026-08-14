import type { VizioControlApi } from './shared/types';

declare global {
  interface Window {
    vizioControl: VizioControlApi;
  }
}

export {};
