import http from 'node:http';
import net from 'node:net';
import { afterEach, describe, expect, it } from 'vitest';
import { WebSocketServer } from 'ws';
import { CdpObserver } from '../electron/services/CdpObserver';

const closers: Array<() => Promise<void>> = [];

afterEach(async () => {
  while (closers.length) await closers.pop()!();
});

describe('SmartCast Chromium observation', () => {
  it('captures an in-memory screen and rediscovers a changed debugging port', async () => {
    const firstPort = await findFreePort(41800);
    const secondPort = await findFreePort(firstPort + 1);
    const first = await startCdp(firstPort, 'Hulu home');
    closers.push(first.close);
    const observer = new CdpObserver('127.0.0.1', {
      start: firstPort,
      end: secondPort,
      concurrency: 2,
      timeoutMs: 100,
    });

    const initial = await observer.observe();
    expect(initial.port).toBe(firstPort);
    expect(initial.dataUrl).toMatch(/^data:image\/jpeg;base64,/);
    expect(initial.focusedText).toContain('Search');
    expect(initial.sensitiveActionVisible).toBe(false);
    expect(initial.sensitiveContextVisible).toBe(false);

    await first.close();
    closers.pop();
    const second = await startCdp(secondPort, 'Hulu results');
    closers.push(second.close);
    const moved = await observer.observe();
    expect(moved.port).toBe(secondPort);
    expect(moved.title).toBe('Hulu results');
    observer.disconnect();
  });

  it('waits for an app debugging target that appears after launch', async () => {
    const port = await findFreePort(41800);
    const observer = new CdpObserver('127.0.0.1', {
      start: port,
      end: port,
      concurrency: 1,
      timeoutMs: 40,
    });
    let delayed: Awaited<ReturnType<typeof startCdp>> | undefined;
    const started = new Promise<void>((resolve, reject) => {
      setTimeout(() => {
        void startCdp(port, 'Hulu ready').then((server) => {
          delayed = server;
          closers.push(server.close);
          resolve();
        }, reject);
      }, 100);
    });

    await expect(observer.waitUntilAvailable(undefined, 1_500)).resolves.toBe(true);
    await started;
    expect((await observer.observe()).title).toBe('Hulu ready');
    observer.disconnect();
    expect(delayed).toBeDefined();
  });

  it('cancels screen-readiness waits immediately', async () => {
    const port = await findFreePort(41800);
    const observer = new CdpObserver('127.0.0.1', {
      start: port,
      end: port,
      concurrency: 1,
      timeoutMs: 40,
    });
    const abort = new AbortController();
    abort.abort();
    await expect(observer.waitUntilAvailable(abort.signal, 1_500)).rejects.toMatchObject({ name: 'AbortError' });
  });

  it('acknowledges every native frame while publishing no more than 24 FPS', async () => {
    const port = await findFreePort(41800);
    const cdp = await startCdp(port, 'Hulu playback');
    closers.push(cdp.close);
    const observer = new CdpObserver('127.0.0.1', {
      start: port,
      end: port,
      concurrency: 1,
      timeoutMs: 100,
    });
    const frames: Array<{ dataUrl: string }> = [];
    const states: string[] = [];
    observer.on('streamFrame', (frame) => frames.push(frame));
    observer.on('streamState', (state) => states.push(state.status));

    observer.startStream(24);
    await waitFor(() => states.includes('live') && frames.length >= 2, 1_000);
    await delay(500);
    observer.stopStream();
    observer.disconnect();

    expect(states).toContain('live');
    expect(frames.length).toBeGreaterThanOrEqual(8);
    expect(frames.length).toBeLessThanOrEqual(15);
    expect(frames.every((frame) => frame.dataUrl.startsWith('data:image/jpeg;base64,'))).toBe(true);
    expect(cdp.frameCount()).toBeGreaterThan(frames.length * 2);
    expect(cdp.ackCount()).toBeGreaterThan(frames.length * 2);
  });

  it('immediately rediscovers a new screen target after an app launch', async () => {
    const firstPort = await findFreePort(41800);
    const secondPort = await findFreePort(firstPort + 1);
    const first = await startCdp(firstPort, 'Hulu profile picker');
    closers.push(first.close);
    const observer = new CdpObserver('127.0.0.1', {
      start: firstPort,
      end: secondPort,
      concurrency: 2,
      timeoutMs: 100,
    });
    const titles: string[] = [];
    observer.on('streamFrame', (frame) => titles.push(frame.title));
    observer.startStream(24);
    await waitFor(() => titles.includes('Hulu profile picker'), 1_000);

    await first.close();
    closers.pop();
    const second = await startCdp(secondPort, 'Hulu home');
    closers.push(second.close);
    observer.notifyAppLaunch();
    await waitFor(() => titles.includes('Hulu home'), 1_000);

    observer.stopStream();
    observer.disconnect();
  });

  it('keeps retrying after an unavailable screen without blocking the next live target', async () => {
    const port = await findFreePort(41800);
    const observer = new CdpObserver('127.0.0.1', {
      start: port,
      end: port,
      concurrency: 1,
      timeoutMs: 40,
    });
    const states: string[] = [];
    observer.on('streamState', (state) => states.push(state.status));
    observer.startStream(24);

    await waitFor(() => states.includes('unavailable'), 1_500);
    await delay(2_750);
    expect(states.filter((state) => state === 'connecting')).toHaveLength(1);
    const cdp = await startCdp(port, 'Hulu recovered');
    closers.push(cdp.close);
    observer.notifyAppLaunch();
    await waitFor(() => states.includes('live'), 2_500);

    observer.stopStream();
    observer.disconnect();
    expect(states.filter((state) => state === 'connecting')).toHaveLength(1);
    expect(states.at(-1)).toBe('live');
  }, 8_000);
});

async function startCdp(port: number, title: string) {
  const sockets = new Set<net.Socket>();
  let acknowledgements = 0;
  let generatedFrames = 0;
  const server = http.createServer((request, response) => {
    if (request.url !== '/json/list') {
      response.writeHead(404).end();
      return;
    }
    response.setHeader('Content-Type', 'application/json');
    response.end(JSON.stringify([{
      id: 'smartcast-page', type: 'page', title, url: 'https://example.test/app',
      webSocketDebuggerUrl: `ws://127.0.0.1:${port}/devtools/page/smartcast-page`,
    }]));
  });
  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
  });
  const websocket = new WebSocketServer({ noServer: true });
  server.on('upgrade', (request, socket, head) => websocket.handleUpgrade(request, socket, head, (client) => websocket.emit('connection', client, request)));
  websocket.on('connection', (client) => {
    let frameTimer: NodeJS.Timeout | null = null;
    const stopFrames = () => {
      if (frameTimer) clearInterval(frameTimer);
      frameTimer = null;
    };
    client.once('close', stopFrames);
    client.on('message', (raw) => {
      const command = JSON.parse(raw.toString()) as { id: number; method: string };
      if (command.method === 'Page.screencastFrameAck') acknowledgements += 1;
      const result = command.method === 'Page.captureScreenshot'
        ? { data: Buffer.from('private-screen').toString('base64') }
        : command.method === 'Accessibility.getFullAXTree'
          ? { nodes: [{
            ignored: false,
            role: { value: 'textbox' },
            name: { value: 'Search' },
            properties: [{ name: 'focused', value: { value: true } }],
          }] }
          : {};
      client.send(JSON.stringify({ id: command.id, result }));
      if (command.method === 'Page.startScreencast' && !frameTimer) {
        frameTimer = setInterval(() => {
          generatedFrames += 1;
          client.send(JSON.stringify({
            method: 'Page.screencastFrame',
            params: {
              data: Buffer.from(`private-screen-${generatedFrames}`).toString('base64'),
              sessionId: generatedFrames,
            },
          }));
        }, 4);
      }
      if (command.method === 'Page.stopScreencast') stopFrames();
    });
  });
  await new Promise<void>((resolve, reject) => server.listen(port, '127.0.0.1', resolve).once('error', reject));
  let closed = false;
  return {
    ackCount: () => acknowledgements,
    frameCount: () => generatedFrames,
    close: async () => {
      if (closed) return;
      closed = true;
      websocket.clients.forEach((client) => client.terminate());
      websocket.close();
      sockets.forEach((socket) => socket.destroy());
      await new Promise<void>((resolve) => server.close(() => resolve()));
    },
  };
}

function delay(milliseconds: number) {
  return new Promise<void>((resolve) => setTimeout(resolve, milliseconds));
}

async function waitFor(predicate: () => boolean, timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error('Timed out waiting for condition.');
    await delay(10);
  }
}

async function findFreePort(start: number) {
  for (let port = start; port < 41950; port += 1) {
    const free = await new Promise<boolean>((resolve) => {
      const server = net.createServer();
      server.once('error', () => resolve(false));
      server.listen(port, '127.0.0.1', () => server.close(() => resolve(true)));
    });
    if (free) return port;
  }
  throw new Error('No test port is available.');
}
