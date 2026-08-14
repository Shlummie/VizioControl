import { build } from 'esbuild';

const production = process.env.NODE_ENV === 'production';

const shared = {
  bundle: true,
  platform: 'node',
  target: 'node22',
  sourcemap: !production,
  external: ['electron'],
  logLevel: 'info',
};

await Promise.all([
  build({
    ...shared,
    entryPoints: ['electron/main.ts'],
    outfile: 'dist-electron/main.cjs',
    format: 'cjs',
  }),
  build({
    ...shared,
    entryPoints: ['electron/preload.ts'],
    outfile: 'dist-electron/preload.cjs',
    format: 'cjs',
  }),
]);
