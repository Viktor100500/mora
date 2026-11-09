import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chromium, webkit } from 'playwright';
import { previewHTML } from '../build-preview.mjs';

const html = await previewHTML();
const artifactDir = process.env.MORA_UI_ARTIFACTS;

for (const [name, engine, mobile] of [['webkit-phone', webkit, true], ['chromium-desktop', chromium, false]]) {
  test(name + ': purchase flow, focus, colours and retry', async () => {
    const browser = await engine.launch(name === 'chromium-desktop' && process.env.MORA_UI_CHROME_CHANNEL
      ? { channel: process.env.MORA_UI_CHROME_CHANNEL } : {});
    const context = await browser.newContext({
      viewport: mobile ? { width: 375, height: 812 } : { width: 900, height: 680 },
      isMobile: mobile, hasTouch: mobile
    });
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.route('**/*', route => route.fulfill({ contentType: 'text/html', body: html }));
    try {
      await page.goto('https://preview.invalid/?theme=dark');
      await page.locator('#form:not(.hidden)').waitFor();
      const amount = page.locator('#amount');
      const done = page.locator('#keyboard-done');
      const send = page.locator('#send');
      assert.equal(await page.evaluate(() => window.__moraPreview.mainVisible), false);
      assert.equal(await send.isDisabled(), true);
      assert.equal(await done.isVisible(), false);
      assert.equal(await page.evaluate(() => document.activeElement.id), '');

      await amount.fill('12,50');
      assert.equal(await done.isVisible(), true);
      await done.click();
      assert.notEqual(await page.evaluate(() => document.activeElement.id), 'amount');
      assert.equal(await done.isVisible(), false);
      assert.ok(await page.evaluate(() => window.__moraPreview.keyboardHides > 0));

      await amount.focus();
      await page.locator('#recent button').click();
      assert.equal(await amount.inputValue(), '12,50');
      assert.notEqual(await page.evaluate(() => document.activeElement.id), 'amount');
      assert.equal(await send.isEnabled(), true);
      assert.equal(await page.locator('#merchant').inputValue(), 'Lidl');

      // Opening a picker while typing must first release the text input.
      await amount.focus();
      await page.locator('#category').dispatchEvent('pointerdown');
      assert.notEqual(await page.evaluate(() => document.activeElement.id), 'amount');
      await page.locator('#category').selectOption('coffee');
      assert.notEqual(await page.evaluate(() => document.activeElement.id), 'amount');
      assert.equal(await amount.inputValue(), '12,50');

      await page.locator('#merchant').focus();
      await page.locator('#merchant').press('Enter');
      assert.equal(await page.evaluate(() => window.__moraPreview.purchases.length), 0);
      assert.notEqual(await page.evaluate(() => document.activeElement.id), 'merchant');
      await page.locator('#note').fill('Проверка');
      await page.locator('.totals').click();
      assert.equal(await done.isVisible(), false);

      // Invalid amounts stay blocked, even after choosing a recent merchant.
      for (const invalid of ['0', '12.345', 'hello']) {
        await amount.fill(invalid);
        assert.equal(await send.isDisabled(), true);
      }
      await amount.fill('12,50');
      await done.click();
      for (const dark of [true, false]) {
        await page.evaluate(value => window.__moraPreview.theme(value), dark);
        const style = await send.evaluate(el => {
          const s = getComputedStyle(el);
          return { color: s.color, bg: s.backgroundColor, opacity: s.opacity };
        });
        assert.equal(style.color, 'rgb(255, 255, 255)');
        assert.equal(style.bg, dark ? 'rgb(64, 130, 106)' : 'rgb(51, 110, 87)');
        assert.equal(style.opacity, '1');
        if (artifactDir) await page.screenshot({ path: artifactDir + '/' + name + (dark ? '-dark.png' : '-light.png'), fullPage: true });
      }
      // Footer must be visible without scrolling even in landscape / a short desktop window.
      await page.setViewportSize({ width: mobile ? 375 : 900, height: 420 });
      await page.evaluate(() => scrollTo(0, 0));
      let bounds = await send.boundingBox();
      assert.ok(bounds.y >= 0 && bounds.y + bounds.height <= 420);
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false);

      await page.evaluate(() => { window.__moraPreview.failNext = true; });
      await send.click();
      assert.equal(await send.isDisabled(), true);
      await page.waitForFunction(() => document.querySelector('#status').textContent.includes('Тестовая ошибка'));
      assert.equal(await amount.inputValue(), '12,50');
      assert.equal(await send.isEnabled(), true);
      const first = await page.evaluate(() => window.__moraPreview.purchases[0]);
      assert.equal(first.amount, 12.5);
      assert.equal(first.category_id, 'coffee');
      assert.equal(first.note, 'Проверка');

      await send.click();
      await page.waitForFunction(() => document.querySelector('#amount').value === '');
      assert.equal(await send.isDisabled(), true);
      const purchases = await page.evaluate(() => window.__moraPreview.purchases);
      assert.equal(purchases.length, 2);
      assert.equal(purchases[0].event_id, purchases[1].event_id, 'a retry must not duplicate a purchase');
      assert.equal(await page.locator('#yay').evaluate(el => el.classList.contains('on')), true);
      assert.deepEqual(errors, []);
    } finally {
      await browser.close();
    }
  });
}
