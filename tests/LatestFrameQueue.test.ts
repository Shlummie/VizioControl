import { describe, expect, it } from 'vitest';
import { LatestFrameQueue, type PreparedFrame } from '../src/latestFrameQueue';

describe('latest screen frame queue', () => {
  it('keeps the current frame visible until its replacement is decoded', async () => {
    const decoded = deferred<PreparedFrame>();
    const committed: string[] = ['current'];
    const queue = new LatestFrameQueue<string>(async () => decoded.promise);

    queue.push('next');
    await tick();
    expect(committed).toEqual(['current']);

    decoded.resolve({ commit: () => committed.push('next') });
    await tick();
    expect(committed).toEqual(['current', 'next']);
  });

  it('drops intermediate waiting frames without starving decoded frames', async () => {
    const first = deferred<PreparedFrame>();
    const newest = deferred<PreparedFrame>();
    const prepared: string[] = [];
    const committed: string[] = [];
    const queue = new LatestFrameQueue<string>(async (dataUrl) => {
      prepared.push(dataUrl);
      return dataUrl === 'frame-1' ? first.promise : newest.promise;
    });

    queue.push('frame-1');
    await tick();
    queue.push('frame-2');
    queue.push('frame-3');
    first.resolve({ commit: () => committed.push('frame-1') });
    await tick();

    expect(prepared).toEqual(['frame-1', 'frame-3']);
    expect(committed).toEqual(['frame-1']);

    newest.resolve({ commit: () => committed.push('frame-3') });
    await tick();
    expect(committed).toEqual(['frame-1', 'frame-3']);
  });

  it('does not reveal a decoded frame after the viewport is cleared or stopped', async () => {
    const cleared = deferred<PreparedFrame>();
    const stopped = deferred<PreparedFrame>();
    const commits: string[] = [];
    const discards: string[] = [];
    const queue = new LatestFrameQueue<string>(async (dataUrl) => dataUrl === 'cleared' ? cleared.promise : stopped.promise);

    queue.push('cleared');
    await tick();
    queue.clear();
    cleared.resolve({ commit: () => commits.push('cleared'), discard: () => discards.push('cleared') });
    await tick();

    queue.push('stopped');
    await tick();
    queue.stop();
    stopped.resolve({ commit: () => commits.push('stopped'), discard: () => discards.push('stopped') });
    await tick();

    expect(commits).toEqual([]);
    expect(discards).toEqual(['cleared', 'stopped']);
  });
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => { resolve = complete; });
  return { promise, resolve };
}

function tick() {
  return new Promise<void>((resolve) => setTimeout(resolve, 0));
}
