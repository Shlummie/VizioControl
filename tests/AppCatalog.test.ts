import { describe, expect, it } from 'vitest';
import { AppCatalog } from '../electron/services/AppCatalog';

describe('embedded quick-app catalog', () => {
  it.each([
    ['Hulu', { appId: '3', namespace: 2, message: '', name: 'Hulu' }],
    ['YouTube', { appId: '1', namespace: 5, message: '', name: 'YouTube' }],
    ['Netflix', { appId: '1', namespace: 3, message: '', name: 'Netflix' }],
  ])('resolves %s without a runtime catalog lookup', async (name, expected) => {
    await expect(new AppCatalog().resolve(name)).resolves.toEqual(expected);
  });

  it('does not fall back to a cloud catalog for unknown app names', async () => {
    await expect(new AppCatalog().resolve('Unknown Service')).rejects.toThrow('local quick launcher');
  });
});
