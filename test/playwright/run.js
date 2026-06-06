const { chromium, request } = require('playwright');
const fs = require('fs');
const tls = require('tls');

fs.mkdirSync('/tmp/playwright-test', { recursive: true });

const TARGETS = [
  { name: 'cloudless-gr', url: 'https://cloudless.gr', label: 'Pi k3s + Cloudflare Tunnel' },
];

const results = [];
let failed = 0;

function rec(target, kind, name, ok, detail = '') {
  results.push({ target, kind, name, ok, detail });
  if (!ok) failed++;
  const tag = ok ? 'PASS' : 'FAIL';
  console.log(`  [${tag}] ${kind}: ${name}${detail ? ' — ' + detail : ''}`);
}

// Retry transient failures from the standby's CDN/ingress path
// (occasional 403 "Host resol..." mid-flight) and any 5xx. Other statuses
// are returned as-is so real bugs aren't masked. Network errors retry too.
async function getWithRetry(ctx, url, opts, label) {
  const MAX_ATTEMPTS = 3;
  const BACKOFF_MS = 3000;
  let lastResp = null;
  let lastErr = null;
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    try {
      const r = await ctx.get(url, opts);
      const transient = r.status() === 403 || r.status() >= 500;
      if (transient && attempt < MAX_ATTEMPTS) {
        console.log(`  ↻ ${label}: status=${r.status()} attempt ${attempt}/${MAX_ATTEMPTS}, retrying in ${BACKOFF_MS}ms`);
        lastResp = r;
        await new Promise(s => setTimeout(s, BACKOFF_MS));
        continue;
      }
      return r;
    } catch (e) {
      lastErr = e;
      if (attempt < MAX_ATTEMPTS) {
        console.log(`  ↻ ${label}: ${e.message} attempt ${attempt}/${MAX_ATTEMPTS}, retrying in ${BACKOFF_MS}ms`);
        await new Promise(s => setTimeout(s, BACKOFF_MS));
      }
    }
  }
  if (lastResp) return lastResp;
  throw lastErr;
}

async function testBackend(target) {
  const ctx = await request.newContext({ ignoreHTTPSErrors: false });
  // /api/health — timed to catch k3s pod OOM restarts (cold start = 5-8s)
  try {
    const t0 = Date.now();
    const r = await getWithRetry(ctx, `${target.url}/api/health`, { timeout: 15000 }, `${target.name} health`);
    const elapsed = Date.now() - t0;
    rec(target.name, 'backend', 'health 200', r.status() === 200, `status=${r.status()}`);
    const body = await r.json();
    // API returns "ok" or "healthy" depending on version — accept both
    const statusOk = body.status === 'ok' || body.status === 'healthy';
    rec(target.name, 'backend', 'health.status ok/healthy', statusOk, JSON.stringify(body));
    rec(target.name, 'backend', 'health.timestamp present', !!body.timestamp);
    // version field is optional — log but don't fail if absent
    if (body.version) {
      rec(target.name, 'backend', 'health.version present', true, `v=${body.version}`);
    } else {
      console.log(`  [SKIP] backend: health.version — field not in response (non-fatal)`);
    }
    target.healthVersion = body.version;
    // Response time: warn at 3s, fail at 8s (k3s pod restart signal)
    if (elapsed > 3000) console.log(`  [WARN] perf: health slow ${elapsed}ms — possible Pi throttle or pod restart`);
    rec(target.name, 'perf', 'health response < 8000ms', elapsed < 8000, `${elapsed}ms`);
  } catch (e) {
    rec(target.name, 'backend', 'health reachable', false, e.message);
  }
  // Root URL — app may redirect (307) or serve directly (200) at "/"
  try {
    const t0 = Date.now();
    const r = await getWithRetry(ctx, target.url, { maxRedirects: 5, timeout: 15000 }, `${target.name} root`);
    const elapsed = Date.now() - t0;
    const status = r.status();
    const finalUrl = r.url();
    const landsOnEn = finalUrl.includes('/en') || finalUrl.endsWith('/');
    rec(target.name, 'backend', 'root reachable (200 or 3xx → /en)', status === 200 && landsOnEn,
        `status=${status} final=${finalUrl}`);
    rec(target.name, 'perf', 'root response < 12000ms', elapsed < 12000, `${elapsed}ms`);
    // Cloudflare header validation — proves traffic flows through CF edge
    const headers = r.headers();
    rec(target.name, 'cf', 'CF-Ray header present', !!headers['cf-ray'], headers['cf-ray'] || 'MISSING');
    rec(target.name, 'cf', 'Server: cloudflare', headers['server'] === 'cloudflare', headers['server'] || 'MISSING');
    const cfCache = headers['cf-cache-status'];
    console.log(`  [INFO] CF-Cache-Status: ${cfCache || 'absent'}`);
    console.log(`  [INFO] cache-control: ${headers['cache-control'] || 'absent'}`);
  } catch (e) {
    rec(target.name, 'backend', 'root reachable', false, e.message);
  }
  await ctx.dispose();
}

async function testTLS(target) {
  const hostname = new URL(target.url).hostname;
  try {
    const daysLeft = await new Promise((resolve, reject) => {
      const sock = tls.connect(443, hostname, { servername: hostname }, () => {
        const cert = sock.getPeerCertificate();
        sock.destroy();
        const exp = new Date(cert.valid_to);
        resolve(Math.floor((exp - Date.now()) / 86400000));
      });
      sock.on('error', reject);
      sock.setTimeout(10000, () => reject(new Error('TLS connect timeout')));
    });
    // Warn at 30 days, fail at 7 days — Cloudflare Universal SSL auto-renews but confirm it does
    rec(target.name, 'infra', 'TLS cert > 7 days', daysLeft > 7, `${daysLeft} days remaining`);
    if (daysLeft <= 30) console.log(`  [WARN] infra: TLS cert expires in ${daysLeft} days — verify CF auto-renewal`);
    else console.log(`  [INFO] TLS cert: ${daysLeft} days remaining`);
  } catch (e) {
    rec(target.name, 'infra', 'TLS cert check', false, e.message);
  }
}

async function testFrontend(target) {
  const browser = await chromium.launch({ headless: true });
  // TLS is validated by the Node.js TLS socket in testTLS (system CA store).
  // Chromium headless uses its own bundled CA store which may not trust Cloudflare's
  // CA in CI/sandbox environments — ignore cert errors here to avoid false failures.
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true });
  const page = await ctx.newPage();
  const consoleErrors = [];
  const failedRequests = [];
  page.on('console', m => { if (m.type() === 'error') consoleErrors.push(m.text()); });
  page.on('requestfailed', r => failedRequests.push(`${r.url()} ${r.failure()?.errorText}`));

  // Inject CWV observers before navigation
  await page.addInitScript(() => {
    window.__lcp = null;
    window.__cls = 0;
    try {
      new PerformanceObserver(list => {
        for (const e of list.getEntries()) window.__lcp = e.startTime;
      }).observe({ type: 'largest-contentful-paint', buffered: true });
      new PerformanceObserver(list => {
        for (const e of list.getEntries()) if (!e.hadRecentInput) window.__cls += e.value;
      }).observe({ type: 'layout-shift', buffered: true });
    } catch (_) {}
  });

  try {
    const t0 = Date.now();
    const resp = await page.goto(target.url, { waitUntil: 'networkidle', timeout: 30000 });
    const pageLoadMs = Date.now() - t0;
    // Use Navigation Timing API for accurate TTFB (responseStart ms from navigation start)
    const ttfb = await page.evaluate(() => {
      const nav = performance.getEntriesByType('navigation')[0];
      return nav ? Math.round(nav.responseStart) : null;
    }) ?? pageLoadMs;
    rec(target.name, 'frontend', 'page loaded 200', resp.status() === 200, `final=${page.url()} status=${resp.status()}`);

    // App may serve at root "/" or under "/en" depending on i18n config
    const finalPageUrl = page.url();
    const landedOk = finalPageUrl.includes('/en') || finalPageUrl.replace(/^https?:\/\/[^/]+/, '') === '/';
    rec(target.name, 'frontend', 'lands on expected path', landedOk, finalPageUrl);

    const title = await page.title();
    rec(target.name, 'frontend', 'has <title>', title.length > 0, JSON.stringify(title));
    target.title = title;

    const hasBody = await page.locator('body').count();
    rec(target.name, 'frontend', '<body> present', hasBody === 1);

    const textLen = (await page.locator('body').innerText()).trim().length;
    rec(target.name, 'frontend', 'body has rendered text', textLen > 50, `${textLen} chars`);

    // Hydration errors — Next.js App Router specific, fatal to interactivity
    const hydrationErrors = consoleErrors.filter(e =>
      /hydration failed|text content does not match|did not match server/i.test(e)
    );
    rec(target.name, 'nextjs', 'no hydration errors', hydrationErrors.length === 0,
        hydrationErrors.length ? hydrationErrors[0].slice(0, 200) : '');

    // All other console errors (excluding known noisy 3rd parties)
    const realErrors = consoleErrors.filter(e =>
      !/sentry|hubspot|stripe|facebook|fbq|hbspt|HubSpot|ResizeObserver|Failed to load resource: the server responded with a status of 4/i.test(e)
      && !/hydration failed|text content does not match|did not match server/i.test(e)
    );
    rec(target.name, 'frontend', 'no console errors', realErrors.length === 0,
        realErrors.length ? `${realErrors.length} err: ${realErrors[0].slice(0,160)}` : '');

    // Network failures (excluding analytics/3rd party and benign Next.js prefetch aborts)
    const realFails = failedRequests.filter(f =>
      !/sentry|hubspot|stripe|facebook|google|hotjar|hsforms|hs-scripts|typekit/i.test(f)
      && !/_rsc=.*ERR_ABORTED/.test(f)  // Next.js RSC prefetch aborts on networkidle — benign
      && !/ERR_ABORTED/.test(f)         // Next.js link prefetch/navigation aborts — benign
    );
    rec(target.name, 'frontend', 'no first-party request failures', realFails.length === 0,
        realFails.length ? realFails[0].slice(0, 160) : '');

    // Core Web Vitals — Pi-appropriate thresholds (2× standard Good)
    await page.waitForTimeout(1000); // flush PerformanceObserver
    const lcp = await page.evaluate(() => window.__lcp);
    const cls = await page.evaluate(() => window.__cls);
    rec(target.name, 'cwv', 'TTFB < 3000ms', ttfb < 3000, `${ttfb}ms`);
    rec(target.name, 'cwv', 'LCP < 5000ms', lcp === null || lcp < 5000, lcp !== null ? `${lcp.toFixed(0)}ms` : 'no LCP entry');
    rec(target.name, 'cwv', 'CLS < 0.25', cls < 0.25, cls.toFixed(3));

    // Screenshot
    const shotPath = `/tmp/playwright-test/${target.name}.png`;
    await page.screenshot({ path: shotPath, fullPage: false });
    rec(target.name, 'frontend', 'screenshot captured', fs.existsSync(shotPath), shotPath);

  } catch (e) {
    rec(target.name, 'frontend', 'page load', false, e.message);
  } finally {
    await ctx.close();
    await browser.close();
  }
}

async function testHAParity() {
  const main = TARGETS.find(t => t.name === 'main');
  const standby = TARGETS.find(t => t.name === 'standby');
  // Both sides now report the build's git commit SHA (the standby moved off
  // its old "0.1.0" semver). They converge after every deploy — the
  // image-sync CronJob rolls the standby within ~1min. This monitor runs
  // every 30min, so a mismatch here means the sync is genuinely stuck (see
  // issue #21), not transient deploy lag — assert equality.
  if (main?.healthVersion && standby?.healthVersion) {
    rec('parity', 'ha', 'health version match', main.healthVersion === standby.healthVersion,
        `main=${main.healthVersion} standby=${standby.healthVersion}`);
  }
  if (main?.title && standby?.title) {
    rec('parity', 'ha', 'title match', main.title === standby.title,
        `main="${main.title}" standby="${standby.title}"`);
  }
}

(async () => {
  for (const t of TARGETS) {
    console.log(`\n=== ${t.name} (${t.label}) ===`);
    await testBackend(t);
    await testTLS(t);
    await testFrontend(t);
  }
  console.log(`\n=== HA parity ===`);
  await testHAParity();

  const total = results.length;
  const passed = total - failed;
  console.log(`\nSUMMARY: ${passed}/${total} passed${failed ? `, ${failed} failed` : ''}`);
  fs.writeFileSync('/tmp/playwright-test/results.json', JSON.stringify(results, null, 2));
  process.exit(failed ? 1 : 0);
})();
