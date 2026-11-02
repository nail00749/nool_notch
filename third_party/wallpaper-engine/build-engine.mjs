// Run from an isolated build directory with the package.json/lockfile beside this file.
// Usage: node build-engine.mjs /absolute/path/to/pinned/webwallgl /absolute/output/directory
import { build } from 'vite';
import { transform } from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { execFileSync } from 'node:child_process';
const [root, output] = process.argv.slice(2);
if (!root || !output) throw new Error('Expected source and output directories');
const expected = '197abe54266c31d346cebc314e49a26b70c960cc';
if (execFileSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim() !== expected) throw new Error('Unexpected upstream revision');
const { glslPlugin, embeddedGlslPlugin } = await import(pathToFileURL(path.join(root, 'scripts/lib/glsl-plugin.mjs')));
const { minRawJsPlugin } = await import(pathToFileURL(path.join(root, 'scripts/lib/min-raw-plugin.mjs')));
await build({
  root, configFile: false, publicDir: false,
  plugins: [glslPlugin(), embeddedGlslPlugin(), minRawJsPlugin()],
  build: {
    target: 'es2022', outDir: output, emptyOutDir: true, minify: false, sourcemap: false,
    lib: { entry: path.join(root, 'renderer/src/api/index.ts'), name: 'WebWallGL', formats: ['umd'], fileName: () => 'webwallgl.global.js' }
  }
});
const result = await transform(fs.readFileSync(path.join(output, 'webwallgl.global.js'), 'utf8'), {
  minify: true, loader: 'js', legalComments: 'external', charset: 'utf8'
});
fs.writeFileSync(path.join(output, 'webwallgl.global.min.js'), result.code);
fs.writeFileSync(path.join(output, 'BUNDLE-NOTICES.txt'), result.legalComments ?? '');
