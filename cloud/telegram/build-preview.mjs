import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
export async function previewHTML() {
  const html = await readFile(resolve(root, 'miniapp/index.html'), 'utf8');
  const fixture = await readFile(resolve(root, 'tests/fixtures/preview.js'), 'utf8');
  return html.replace('<script src="https://telegram.org/js/telegram-web-app.js"></script>',
    '<script>' + fixture + '</script>')
    .replace('data-api=""', 'data-api="https://preview.invalid/mora"');
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const output = process.argv[2] ? resolve(process.argv[2])
    : resolve(root, '../../build/Previews/telegram-form-ui/miniapp/index.html');
  await mkdir(dirname(output), { recursive: true });
  await writeFile(output, await previewHTML());
  console.log(output);
}
