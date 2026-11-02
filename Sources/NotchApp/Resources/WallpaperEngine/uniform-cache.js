(() => {
  'use strict';
  let installed = false, calls = 0, skipped = 0;
  const decorated = new WeakSet();
  const scalar = /^uniform([1-4])(f|i|ui)$/;
  const vector = /^uniform([1-4])(f|i|ui)v$/;
  const matrix = /^uniformMatrix([2-4])(?:x([2-4]))?fv$/;
  const types = new Map([
    [0x1406, ['f', 1]], [0x8B50, ['f', 2]], [0x8B51, ['f', 3]], [0x8B52, ['f', 4]],
    [0x1404, ['i', 1]], [0x8B53, ['i', 2]], [0x8B54, ['i', 3]], [0x8B55, ['i', 4]],
    [0x8B56, ['i', 1]], [0x8B57, ['i', 2]], [0x8B58, ['i', 3]], [0x8B59, ['i', 4]],
    [0x1405, ['ui', 1]], [0x8DC6, ['ui', 2]], [0x8DC7, ['ui', 3]], [0x8DC8, ['ui', 4]],
    [0x8B5A, ['matrix', 2, 2]], [0x8B5B, ['matrix', 3, 3]], [0x8B5C, ['matrix', 4, 4]],
    [0x8B65, ['matrix', 2, 3]], [0x8B66, ['matrix', 2, 4]], [0x8B67, ['matrix', 3, 2]],
    [0x8B68, ['matrix', 3, 4]], [0x8B69, ['matrix', 4, 2]], [0x8B6A, ['matrix', 4, 3]],
  ]);
  const samplers = new Set([0x8B5E, 0x8B5F, 0x8B60, 0x8B62, 0x8DC1, 0x8DC4, 0x8DC5, 0x8DCA, 0x8DCB, 0x8DCC, 0x8DCF, 0x8DD2, 0x8DD3, 0x8DD4, 0x8DD7]);
  for (const sampler of samplers) types.set(sampler, ['i', 1]);

  function snapshot(name, args) {
    let match = scalar.exec(name), values, kind, start = 0, count, inspectElements = false;
    if (match) {
      if (args.length !== Number(match[1])) return null;
      values = args; count = args.length; kind = match[2];
    } else {
      match = vector.exec(name);
      const dimensions = matrix.exec(name);
      if (!match && !dimensions) return null;
      const matrixMode = !!dimensions;
      if (matrixMode && args[0] !== false) return null;
      const data = args[matrixMode ? 1 : 0];
      if (!Array.isArray(data) && !(ArrayBuffer.isView(data) && typeof data.length === 'number')) return null;
      const offsetIndex = matrixMode ? 2 : 1;
      if (args.length > offsetIndex + 2) return null;
      const offset = args[offsetIndex] === undefined ? 0 : args[offsetIndex];
      const length = args[offsetIndex + 1] === undefined || args[offsetIndex + 1] === 0 ? data.length - offset : args[offsetIndex + 1];
      const width = matrixMode ? Number(dimensions[1]) * Number(dimensions[2] || dimensions[1]) : Number(match[1]);
      if (!Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(length) || length <= 0 || length > 64 || offset + length > data.length || length % width) return null;
      values = data; start = offset; count = length;
      inspectElements = Array.isArray(data);
      kind = matrixMode ? 'f' : match[2];
    }
    for (let i = 0; i < count; i++) {
      // Accessor/holey arrays can change between validation and native WebIDL
      // conversion. Only ordinary numeric data elements are cacheable.
      if (inspectElements) {
        const descriptor = Object.getOwnPropertyDescriptor(values, start + i);
        if (!descriptor || !('value' in descriptor)) return null;
      }
      const value = values[start + i];
      if (typeof value !== 'number' || !Number.isFinite(value)) return null;
      if (kind === 'i' && (!Number.isInteger(value) || value < -2147483648 || value > 2147483647)) return null;
      if (kind === 'ui' && (!Number.isInteger(value) || value < 0 || value > 4294967295)) return null;
    }
    return { data: values, start, count };
  }

  function decorate(gl, canvas) {
    if (!gl || decorated.has(gl)) return;
    decorated.add(gl);
    const owners = new WeakMap(), versions = new WeakMap(), deleted = new WeakSet();
    let cached = new WeakMap(), reflected = new WeakMap(), current = null, epoch = 0, lost = false, disabled = false;
    const reset = () => { cached = new WeakMap(); };
    const reflect = (program, name) => {
      let uniforms = reflected.get(program);
      if (!uniforms) {
        uniforms = new Map();
        try {
          if (gl.getProgramParameter(program, gl.LINK_STATUS) !== true) throw new Error('Program is not linked');
          const count = gl.getProgramParameter(program, gl.ACTIVE_UNIFORMS);
          if (!Number.isSafeInteger(count) || count < 0 || count > 4096) throw new Error('Unknown uniform count');
          for (let i = 0; i < count; i++) {
            const info = gl.getActiveUniform(program, i);
            if (!info || !/^\w+(?:\[0\])?$/.test(info.name) || !Number.isSafeInteger(info.size) || info.size < 1) continue;
            const base = info.name.replace(/\[0\]$/, '');
            const type = types.get(info.type);
            // Unknown, nested or ambiguous reflected uniforms always forward.
            const metadata = type ? { type, size: info.size, sampler: samplers.has(info.type) } : null;
            uniforms.set(base, uniforms.has(base) ? null : metadata);
          }
        } catch { uniforms.clear(); }
        reflected.set(program, uniforms);
      }
      const match = /^(\w+)(?:\[(\d+)\])?$/.exec(name);
      if (!match) return null;
      const metadata = uniforms.get(match[1]);
      const index = match[2] === undefined ? 0 : Number(match[2]);
      if (!metadata || !Number.isSafeInteger(index) || index >= metadata.size) return null;
      return { type: metadata.type, sampler: metadata.sampler, remaining: metadata.size - index };
    };
    if (typeof gl.beginTransformFeedback === 'function') {
      const original = gl.beginTransformFeedback;
      gl.beginTransformFeedback = function () {
        if (this === gl) {
          // Active transform feedback can reject useProgram without throwing.
          // The scene player never uses it; conservatively retain native calls
          // forever on any context that does, rather than querying state/frame.
          disabled = true;
          reset();
        }
        return original.apply(this, arguments);
      };
    }
    const originalLocation = gl.getUniformLocation;
    gl.getUniformLocation = function (program, name) {
      const location = originalLocation.apply(this, arguments);
      if (this === gl && location && typeof name === 'string') {
        owners.set(location, { program, name, base: name.replace(/\[\d+\]/g, ''), version: versions.get(program) || 0, epoch, metadata: reflect(program, name) });
      }
      return location;
    };
    for (const name of ['useProgram', 'linkProgram', 'deleteProgram']) {
      const original = gl[name];
      gl[name] = function (program) {
        const result = original.apply(this, arguments);
        if (this !== gl) return result;
        if (name === 'useProgram') current = deleted.has(program) ? null : program;
        else {
          reset();
          if (program && typeof program === 'object') reflected.delete(program);
          if (program && typeof program === 'object') versions.set(program, (versions.get(program) || 0) + 1);
          if (name === 'deleteProgram' && program && typeof program === 'object') {
            deleted.add(program);
            if (current === program) current = null;
          }
        }
        return result;
      };
    }
    const names = [];
    for (let n = 1; n <= 4; n++) {
      for (const kind of ['f', 'i', 'ui']) names.push(`uniform${n}${kind}`, `uniform${n}${kind}v`);
    }
    for (let columns = 2; columns <= 4; columns++) {
      names.push(`uniformMatrix${columns}fv`);
      for (let rows = 2; rows <= 4; rows++) if (rows !== columns) names.push(`uniformMatrix${columns}x${rows}fv`);
    }
    for (const name of names) {
      const original = gl[name];
      if (typeof original !== 'function') continue;
      gl[name] = function (location, ...args) {
        if (this !== gl) return original.call(this, location, ...args);
        calls++;
        const owner = location && typeof location === 'object' ? owners.get(location) : null;
        const valid = owner && !disabled && !lost && owner.epoch === epoch && owner.program === current && !deleted.has(current) && owner.version === (versions.get(current) || 0);
        let group = owner && cached.get(owner.program);
        let values = valid && owner.metadata ? snapshot(name, args) : null;
        if (values) {
          const [kind, columns, rows] = owner.metadata.type;
          const method = kind === 'matrix' ? `uniformMatrix${columns}${columns === rows ? '' : `x${rows}`}fv` : `uniform${columns}${kind}`;
          const width = columns * (rows || 1);
          if ((name !== method && (kind === 'matrix' || name !== `${method}v`)) || values.count / width > owner.metadata.remaining) values = null;
          // Units 0...7 are valid on every supported WebGL context. Forward
          // other sampler values to preserve native unit-range validation.
          if (values && owner.metadata.sampler) {
            for (let i = 0; i < values.count; i++) if (values.data[values.start + i] < 0 || values.data[values.start + i] > 7) { values = null; break; }
          }
        }
        const previous = group && group.get(owner.base);
        if (values && previous && previous.name === owner.name && previous.method === name && previous.values.length === values.count && previous.values.every((value, i) => Object.is(value, values.data[values.start + i]))) {
          skipped++;
          return;
        }
        // All writes aliasing this uniform array invalidate one another. Clear
        // before forwarding, including invalid calls; never hide an exception.
        if (group) group.delete(owner.base);
        const result = original.call(this, location, ...args);
        if (values) {
          if (!group) cached.set(owner.program, group = new Map());
          const copy = new Array(values.count);
          for (let i = 0; i < values.count; i++) copy[i] = values.data[values.start + i];
          group.set(owner.base, { name: owner.name, method: name, values: copy });
        }
        return result;
      };
    }
    canvas.addEventListener('webglcontextlost', () => { lost = true; epoch++; current = null; reflected = new WeakMap(); reset(); });
    canvas.addEventListener('webglcontextrestored', () => { lost = false; epoch++; current = null; reflected = new WeakMap(); reset(); });
  }

  window.NooLUniformCache = {
    install() {
      if (installed) return;
      installed = true;
      const original = HTMLCanvasElement.prototype.getContext;
      HTMLCanvasElement.prototype.getContext = function (kind, ...args) {
        const context = original.call(this, kind, ...args);
        if (kind === 'webgl2' || kind === 'webgl' || kind === 'experimental-webgl') decorate(context, this);
        return context;
      };
    },
    stats: () => ({ calls, skipped }),
  };
})();
