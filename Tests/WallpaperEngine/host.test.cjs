const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const hostPath = path.resolve(__dirname, '../../Sources/NotchApp/Resources/WallpaperEngine/host.js');
const code = fs.readFileSync(hostPath, 'utf8');
const tick = () => new Promise(setImmediate);

function harness({ reject = false, delayed = false } = {}) {
  let resolveMount;
  let clears = 0;
  let destroys = 0;
  const calls = [], messages = [], urls = [];
  const listeners = new Map();
  const instance = {
    stats: { running: true, fps: 60 },
    setFps: (n) => calls.push(['fps', n]),
    setVolume: (n) => calls.push(['volume', n]),
    setFit: (fit) => calls.push(['fit', fit]),
    pushPointer: (x, y) => calls.push(['pointer', x, y]),
    pointerLeave: () => calls.push(['leave']),
    pause: () => calls.push(['pause']),
    resume: () => calls.push(['resume']),
    destroy: () => destroys++,
  };
  const window = {
    devicePixelRatio: 2,
    webkit: { messageHandlers: { noolWallpaper: { postMessage: (value) => messages.push(value) } } },
    addEventListener: (type, fn) => listeners.set(type, fn),
    removeEventListener: (type, fn) => { if (listeners.get(type) === fn) listeners.delete(type); },
  };
  const error = new Error('Invalid package');
  error.instance = instance;
  const context = {
    window, document: { getElementById: () => ({}) },
    setInterval: (fn) => { context.heartbeat = fn; return 1; },
    clearInterval: () => clears++,
    fetch: async (url) => {
      urls.push(url);
      return { ok: true, status: 200, arrayBuffer: async () => new ArrayBuffer(8), json: async () => ({ type: 'scene', file: 'scene.json' }) };
    },
    WebWallGL: {
      bytesSource: (bytes, project) => ({ bytes, project }),
      mount: (_element, options) => {
        calls.push(['options', options]);
        return reject ? Promise.reject(error) : delayed ? new Promise((resolve) => { resolveMount = resolve; }) : Promise.resolve(instance);
      },
    },
  };
  vm.runInNewContext(code, context, { filename: hostPath });
  return { context, window, calls, messages, urls, listeners, instance, get destroys() { return destroys; }, get clears() { return clears; }, resolve: () => resolveMount(instance) };
}

test('queues settings during loading, uses local assets and disables scripts/audio', async () => {
  const h = harness();
  h.window.noolWallpaper.apply({ playing: true, framesPerSecond: 90, scaleMode: 'fit', cursor: { x: 0.2, y: 0.7 } });
  await tick();
  assert(h.messages.some((m) => m.status === 'ready'));
  for (const expected of [['resume'], ['fps', 90], ['volume', 0], ['fit', 'contain'], ['pointer', 0.2, 0.7]]) {
    assert(h.calls.some((call) => JSON.stringify(call) === JSON.stringify(expected)));
  }
  const options = h.calls.find((call) => call[0] === 'options')[1];
  assert.equal(options.scripts, false);
  assert.equal(options.audio, null);
  assert.equal(options.renderDpr, 2);
  assert(h.urls.every((url) => url.startsWith('noolwe://runtime/project/')));
  h.context.heartbeat();
  assert.equal(h.messages.at(-1).status, 'frame');
  const count = h.messages.length;
  h.window.noolWallpaper.stop();
  h.context.heartbeat();
  assert.equal(h.messages.length, count);
  assert.equal(h.destroys, 1);
  assert.equal(h.clears, 1);
  assert.equal(h.listeners.has('error'), false);
});

test('cleans the error-attached instance after a rejected mount', async () => {
  const h = harness({ reject: true });
  await tick();
  assert.equal(h.destroys, 1);
  assert.equal(h.messages.filter((message) => message.status === 'failure').length, 1);
  assert.equal(h.window.noolWallpaper.getState().destroyed, true);
});

test('pointer movement preserves playback clock and configuration while transitions still apply', async () => {
  const h = harness();
  await tick();
  h.window.noolWallpaper.apply({ playing: true });
  h.calls.length = 0;
  for (let i = 0; i < 30; i++) h.window.noolWallpaper.apply({ cursor: { x: i / 30, y: 0.5 } });
  assert.equal(h.calls.length, 30);
  assert(h.calls.every(([name]) => name === 'pointer'));
  h.calls.length = 0;
  h.window.noolWallpaper.apply({ playing: true, framesPerSecond: 60, scaleMode: 'fill' });
  assert.equal(h.calls.length, 0);
  h.window.noolWallpaper.apply({ playing: false, framesPerSecond: 30, scaleMode: 'fit' });
  assert.deepEqual(h.calls, [['fps', 30], ['fit', 'contain'], ['pause']]);
  h.calls.length = 0;
  h.window.noolWallpaper.apply({ cursor: null });
  h.window.noolWallpaper.apply({ cursor: null });
  assert.deepEqual(h.calls, [['leave']]);
  h.window.noolWallpaper.apply({ playing: true });
  assert.deepEqual(h.calls.at(-1), ['resume']);
});

test('destroy during pending mount disposes the eventual instance without ready', async () => {
  const h = harness({ delayed: true });
  await tick();
  h.window.noolWallpaper.destroy();
  h.resolve();
  await tick();
  assert.equal(h.destroys, 1);
  assert.equal(h.messages.length, 0);
});

for (const type of ['error', 'unhandledrejection']) {
  test(`uncaught ${type} reports failure and releases the scene without suppressing the browser error`, async () => {
    const h = harness();
    await tick();
    const event = { error: new Error('Render failed'), reason: new Error('Render failed'), preventDefault: () => assert.fail('Must not suppress browser diagnostics') };
    h.listeners.get(type)(event);
    assert.equal(h.messages.at(-1).status, 'failure');
    assert.equal(h.destroys, 1);
    assert.equal(h.clears, 1);
    assert.equal(h.listeners.has(type), false);
  });
}

test('failed native messaging still releases the running scene', async () => {
  const h = harness();
  await tick();
  h.window.webkit.messageHandlers.noolWallpaper.postMessage = () => { throw new Error('Bridge unavailable'); };
  assert.throws(() => h.listeners.get('error')({ error: new Error('Render failed') }), /Bridge unavailable/);
  assert.equal(h.destroys, 1);
  assert.equal(h.clears, 1);
  assert.equal(h.window.noolWallpaper.getState().destroyed, true);
});
