const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(path.resolve(__dirname, '../../Sources/NotchApp/Resources/WallpaperEngine/uniform-cache.js'), 'utf8');

function harness(enabled = true) {
  const calls = [], states = new Map(), errors = [], events = new Map();
  let current = null, feedback = false;
  const active = [
    { name: 'color', type: 0x8B52, size: 1 },
    { name: 'items[0]', type: 0x1406, size: 4 },
    { name: 'matrix', type: 0x8B5A, size: 1 },
    { name: 'vector', type: 0x8B50, size: 1 },
    { name: 'value', type: 0x1406, size: 1 },
  ];
  const gl = {
    ACTIVE_UNIFORMS: 0x8B86,
    LINK_STATUS: 0x8B82,
    reflectionQueries: 0,
    getProgramParameter(program, parameter) { this.reflectionQueries++; return parameter === this.LINK_STATUS ? program.linked !== false && !program.deleted : active.length; },
    getActiveUniform(_program, index) { return active[index]; },
    getUniformLocation(program, name) { return program.linked === false || program.deleted ? null : { program, name, generation: program.generation || 0 }; },
    useProgram(program) {
      if (feedback || program && (program.linked === false || program.deleted)) { errors.push('program switch rejected'); return; }
      current = program;
    },
    linkProgram(program) { states.delete(program); program.generation = (program.generation || 0) + 1; program.linked = !program.failLink; },
    deleteProgram(program) { program.deleted = true; states.delete(program); },
    beginTransformFeedback() { feedback = true; },
    endTransformFeedback() { feedback = false; },
  };
  for (const method of ['uniform1f', 'uniform1i', 'uniform1ui', 'uniform2f', 'uniform3f', 'uniform4f', 'uniform1fv', 'uniform2fv', 'uniform3fv', 'uniform4fv', 'uniform1iv', 'uniformMatrix2fv', 'uniformMatrix3fv', 'uniformMatrix4fv', 'uniformMatrix2x3fv']) {
    gl[method] = function (location, ...args) {
      if (this !== gl) throw new TypeError('Illegal invocation');
      calls.push([method, location && location.name, args]);
      if (location === null) return;
      if (!location || current !== location.program || location.generation !== (location.program.generation || 0)) { errors.push('invalid program'); return; }
      if (method.startsWith('uniformMatrix') && args[0] !== false) { errors.push('transpose'); return; }
      const array = method.endsWith('v');
      const matrix = method.startsWith('uniformMatrix');
      const data = array ? args[matrix ? 1 : 0] : args;
      const offsetIndex = matrix ? 2 : 1;
      const offset = array ? args[offsetIndex] || 0 : 0;
      const length = array ? args[offsetIndex + 1] || data.length - offset : data.length;
      if (offset < 0 || length <= 0 || offset + length > data.length) { errors.push('range'); return; }
      const base = location.name.replace(/\[\d+\]/g, '');
      const declared = active.find((info) => info.name.replace(/\[0\]$/, '') === base);
      const width = base === 'color' || base === 'matrix' ? 4 : base === 'vector' ? 2 : 1;
      const index = Number(/\[(\d+)\]/.exec(location.name)?.[1] || 0);
      if (declared && (method.endsWith('i') || method.endsWith('iv') || method.endsWith('ui') || length / width > declared.size - index)) { errors.push('uniform type or bounds'); return; }
      let state = states.get(current); if (!state) states.set(current, state = new Map());
      state.set(base, Array.from(data).slice(offset, offset + length));
    };
  }
  class Canvas {
    getContext(kind) {
      if (!(this instanceof Canvas)) throw new TypeError('Illegal canvas invocation');
      return kind === '2d' ? null : gl;
    }
    addEventListener(name, fn) { events.set(name, fn); }
  }
  const context = { window: {}, HTMLCanvasElement: Canvas, ArrayBuffer };
  vm.runInNewContext(source, context);
  if (enabled) context.window.NooLUniformCache.install();
  const canvas = new Canvas(); canvas.getContext('webgl2');
  return { gl, canvas, calls, errors, states, events, adapter: context.window.NooLUniformCache, Canvas };
}

test('opt-in install is idempotent, keeps receiver errors, and suppresses redundant scalar calls', () => {
  const h = harness(false), p = {};
  h.adapter.install(); h.adapter.install(); h.canvas.getContext('webgl2');
  h.gl.useProgram(p);
  const a = h.gl.getUniformLocation(p, 'color');
  h.gl.uniform4f(a, 1, 0.5, 0.2, 1); h.gl.uniform4f(a, 1, 0.5, 0.2, 1);
  assert.equal(h.calls.length, 1);
  assert.deepEqual({ ...h.adapter.stats() }, { calls: 2, skipped: 1 });
  assert.throws(() => h.gl.uniform1f.call({}, a, 1), TypeError);
  assert.throws(() => h.Canvas.prototype.getContext.call({}, 'webgl2'), TypeError);
});

test('program switching, aliases, changing setter types and mutable arrays preserve final state', () => {
  const before = harness(false), after = harness(true), a = {}, b = {};
  const exercise = (h) => {
    h.gl.useProgram(a);
    const x = h.gl.getUniformLocation(a, 'items[0]');
    const alias = h.gl.getUniformLocation(a, 'items');
    const y = h.gl.getUniformLocation(a, 'items[1]');
    const data = new Float32Array([1, 2, 3, 4]);
    h.gl.uniform1fv(x, data); h.gl.uniform1fv(x, data);
    data[2] = 9; h.gl.uniform1fv(x, data);
    h.gl.uniform1f(y, 7); h.gl.uniform1fv(x, data);
    h.gl.uniform1fv(alias, data); h.gl.uniform1fv(x, data);
    h.gl.uniform1i(x, 2); h.gl.uniform1f(x, 2);
    h.gl.useProgram(b);
    const z = h.gl.getUniformLocation(b, 'items');
    h.gl.uniform1f(z, 8); h.gl.uniform1f(x, 4);
    h.gl.useProgram(a); h.gl.uniform1f(x, 2);
    return [h.states.get(a).get('items'), h.states.get(b).get('items')];
  };
  assert.deepEqual(exercise(after), exercise(before));
  assert.deepEqual(after.errors, before.errors);
  assert(after.calls.length < before.calls.length);
});

test('WebGL2 ranges compare effective contents and read mutated matrix arrays', () => {
  const h = harness(), p = {}; h.gl.useProgram(p);
  const x = h.gl.getUniformLocation(p, 'matrix');
  const data = new Float32Array([99, 1, 0, 0, 1, 99]);
  h.gl.uniformMatrix2fv(x, false, data, 1, 4);
  h.gl.uniformMatrix2fv(x, false, new Float32Array([1, 0, 0, 1]));
  assert.equal(h.calls.length, 1);
  data[1] = 2; h.gl.uniformMatrix2fv(x, false, data, 1, 4);
  assert.equal(h.calls.length, 2);
  const vector = h.gl.getUniformLocation(p, 'vector');
  h.gl.uniform2fv(vector, [0, 0, 3, 4], 2, 0);
  h.gl.uniform2fv(vector, [3, 4]);
  assert.equal(h.calls.length, 3);
});

test('invalid, unknown, nonfinite and large calls always reach the original method', () => {
  const h = harness(), p = {}; h.gl.useProgram(p);
  const x = h.gl.getUniformLocation(p, 'value');
  const accessor = [1]; Object.defineProperty(accessor, 0, { get: () => 1 });
  const attempts = [
    () => h.gl.uniform1f(null, 2),
    () => h.gl.uniform1f({ program: p, name: 'unknown' }, 2),
    () => h.gl.uniform1f(x, NaN),
    () => h.gl.uniform1i(x, 1.5),
    () => h.gl.uniformMatrix2fv(x, true, [1, 0, 0, 1]),
    () => h.gl.uniform1fv(x, [1, 2], -1),
    () => h.gl.uniform1fv(x, new Float32Array(65)),
    () => h.gl.uniform1fv(x, accessor),
  ];
  for (const attempt of attempts) { attempt(); attempt(); }
  assert.equal(h.calls.length, attempts.length * 2);
  assert.equal(h.adapter.stats().skipped, 0);
});

test('link, delete and context restoration invalidate old locations and cached values', () => {
  const h = harness(), p = {}; h.gl.useProgram(p);
  let x = h.gl.getUniformLocation(p, 'value');
  h.gl.uniform1f(x, 1); h.gl.uniform1f(x, 1);
  h.gl.linkProgram(p); h.gl.uniform1f(x, 1); h.gl.uniform1f(x, 1);
  assert.equal(h.calls.length, 3);
  x = h.gl.getUniformLocation(p, 'value'); h.gl.uniform1f(x, 1); h.gl.uniform1f(x, 1);
  assert.equal(h.calls.length, 4);
  h.events.get('webglcontextlost')(); h.gl.uniform1f(x, 1);
  h.events.get('webglcontextrestored')(); h.gl.useProgram(p);
  h.gl.uniform1f(x, 1); h.gl.uniform1f(x, 1);
  assert.equal(h.calls.length, 7);
  x = h.gl.getUniformLocation(p, 'value'); h.gl.uniform1f(x, 1); h.gl.uniform1f(x, 1);
  assert.equal(h.calls.length, 8);
  h.gl.deleteProgram(p); h.gl.useProgram(p); h.gl.uniform1f(x, 1); h.gl.uniform1f(x, 1);
  assert.equal(h.calls.length, 10);
});

test('declared GL type and remaining array bounds gate caching; reflection runs once', () => {
  const before = harness(false), after = harness(true), p = {};
  const exercise = (h) => {
    h.gl.useProgram(p);
    const scalar = h.gl.getUniformLocation(p, 'value');
    const tail = h.gl.getUniformLocation(p, 'items[3]');
    const nested = h.gl.getUniformLocation(p, 'nested[0].field');
    for (let i = 0; i < 2; i++) {
      h.gl.uniform1i(scalar, 2);
      h.gl.uniform1fv(tail, [1, 2]);
      h.gl.uniform1f(nested, 3);
    }
    h.gl.uniform1f(scalar, 4); h.gl.uniform1f(scalar, 4);
  };
  exercise(before); exercise(after);
  assert.deepEqual(after.errors, before.errors);
  assert.equal(after.calls.length, before.calls.length - 1);
  assert.equal(after.gl.reflectionQueries, 2);
});

test('failed program switches from transform feedback, unlinked and deleted programs preserve native errors', () => {
  for (const reason of ['feedback', 'unlinked', 'deleted']) {
    const before = harness(false), after = harness(true);
    const exercise = (h) => {
      const a = {}, b = {};
      h.gl.useProgram(b);
      const locationB = h.gl.getUniformLocation(b, 'value');
      h.gl.uniform1f(locationB, 2);
      h.gl.useProgram(a);
      const locationA = h.gl.getUniformLocation(a, 'value');
      h.gl.uniform1f(locationA, 1);
      if (reason === 'feedback') h.gl.beginTransformFeedback();
      if (reason === 'unlinked') { b.failLink = true; h.gl.linkProgram(b); }
      if (reason === 'deleted') h.gl.deleteProgram(b);
      h.gl.useProgram(b);
      h.gl.uniform1f(locationB, 2); h.gl.uniform1f(locationB, 2);
      h.gl.uniform1f(locationA, 3); h.gl.uniform1f(locationA, 3);
      if (reason === 'feedback') {
        h.gl.endTransformFeedback(); h.gl.useProgram(b);
        h.gl.uniform1f(locationB, 4); h.gl.uniform1f(locationB, 4);
      } else assert.equal(h.gl.getUniformLocation(b, 'value'), null);
    };
    exercise(before); exercise(after);
    assert.deepEqual(after.errors, before.errors, reason);
    assert.deepEqual(after.states, before.states, reason);
    assert.equal(after.calls.length, before.calls.length, reason);
  }
});

test('failed reflection forwards every uniform call', () => {
  const h = harness(), p = {}; h.gl.useProgram(p);
  h.gl.getProgramParameter = () => { throw new Error('reflection failed'); };
  const location = h.gl.getUniformLocation(p, 'value');
  h.gl.uniform1f(location, 1); h.gl.uniform1f(location, 1);
  assert.equal(h.calls.length, 2);
  assert.equal(h.adapter.stats().skipped, 0);
});
