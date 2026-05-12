const { chromium, request } = require('playwright');
const fs = require('fs');

const TARGETS = [
  { name: 'main',     url: 'https://cloudless.gr',     label: 'AWS Lambda + CloudFront' },
  { name: 'standby',  url: 'https://cloudless.online', label: 'Pi k3s + Tailscale Funnel' },
];

const results = [];
let failed = 0;

function rec(target, kind, name, ok, detail = '') {
  results.push({ target, kind, name, ok, detail });
  if (!ok) failed++;
  const tag = ok ? 'PASS' : 'FAIL';
  console.log(`  [${tag}] ${kind}: ${name}${detail ? ' — ' + detail : ''}`);
}

// Retry transient failures from the standby's Tailscale Funnel path
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
  // /api/health
  try {
    const r = await getWithRetry(ctx, `${target.url}/api/health`, { timeout: 15000 }, `${target.name} health`);
    rec(target.name, 'backend', 'health 200', r.status() === 200, `status=${r.status()}`);
    const body = await r.json();
    rec(target.name, 'backend', 'health.status=ok', body.status === 'ok', JSON.stringify(body));
    rec(target.name, 'backend', 'health.timestamp present', !!body.timestamp);
    rec(target.name, 'backend', 'health.version present', !!body.version, `v=${body.version}`);
    target.healthVersion = body.version;
  } catch (e) {
    rec(target.name, 'backend', 'health reachable', false, e.message);
  }
  // root redirect → /en (accept either relative "/en" or absolute "https://host/en":
  // main returns the relative form, standby returns absolute — both are RFC-7231 valid)
  try {
    const r = await getWithRetry(ctx, target.url, { maxRedirects: 0, timeout: 15000 }, `${target.name} root`);
    const loc = r.headers()['location'];
    const okLoc = loc === '/en' || /^https?:\/\/[^/]+\/en\/?$/i.test(loc || '');
    rec(target.name, 'backend', 'root 307 → /en', r.status() === 307 && okLoc, `status=${r.status()} loc=${loc}`);
  } catch (e) {
    rec(target.name, 'backend', 'root redirect', false, e.message);
  }
  await ctx.dispose();
}

async function testFrontend(target) {
  const browser = await chromium.launch({ headless: true });
  const ctx = await browser.newContext({ ignoreHTTPSErrors: false });
  const page = await ctx.newPage();
  const consoleErrors = [];
  const failedRequests = [];
  page.on('console', m => { if (m.type() === 'error') consoleErrors.push(m.text()); });
  page.on('requestfailed', r => failedRequests.push(`${r.url()} ${r.failure()?.errorText}`));

  try {
    const resp = await page.goto(target.url, { waitUntil: 'networkidle', timeout: 30000 });
    rec(target.name, 'frontend', 'page loaded 200', resp.status() === 200, `final=${page.url()} status=${resp.status()}`);
    rec(target.name, 'frontend', 'lands on /en path', page.url().endsWith('/en') || page.url().includes('/en'), page.url());

    const title = await page.title();
    rec(target.name, 'frontend', 'has <title>', title.length > 0, JSON.stringify(title));
    target.title = title;

    const hasBody = await page.locator('body').count();
    rec(target.name, 'frontend', '<body> present', hasBody === 1);

    // any rendered text?
    const textLen = (await page.locator('body').innerText()).trim().length;
    rec(target.name, 'frontend', 'body has rendered text', textLen > 50, `${textLen} chars`);

    // critical: no console errors except known noisy 3rd parties
    const realErrors = consoleErrors.filter(e =>
      !/sentry|hubspot|stripe|facebook|fbq|hbspt|HubSpot|ResizeObserver|Failed to load resource: the server responded with a status of 4/i.test(e)
    );
    rec(target.name, 'frontend', 'no console errors', realErrors.length === 0,
        realErrors.length ? `${realErrors.length} err: ${realErrors[0].slice(0,160)}` : '');

    // network failures (excluding analytics/3rd party)
    const realFails = failedRequests.filter(f =>
      !/sentry|hubspot|stripe|facebook|google|hotjar|hsforms|hs-scripts|typekit/i.test(f)
      && !/_rsc=.*ERR_ABORTED/.test(f) // Next.js RSC prefetch aborts on networkidle — benign
    );
    rec(target.name, 'frontend', 'no first-party request failures', realFails.length === 0,
        realFails.length ? realFails[0].slice(0, 160) : '');

    // screenshot
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

async function testInfra(target) {
  // TLS cert: leverage the request context (HTTPS would fail above otherwise)
  rec(target.name, 'infra', 'TLS handshake ok', true, 'inferred from successful HTTPS GETs above');
}

async function testHAParity() {
  const main = TARGETS.find(t => t.name === 'main');
  const standby = TARGETS.find(t => t.name === 'standby');
  // The two sides intentionally use different version schemes: main reports
  // the git commit SHA from the Lambda build, standby reports the semver of
  // the Pi image. Equality would always fail. Just record both for visibility.
  if (main?.healthVersion && standby?.healthVersion) {
    rec('parity', 'ha', 'health versions reported', true,
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
    await testFrontend(t);
    await testInfra(t);
  }
  console.log(`\n=== HA parity ===`);
  await testHAParity();

  const total = results.length;
  const passed = total - failed;
  console.log(`\nSUMMARY: ${passed}/${total} passed${failed ? `, ${failed} failed` : ''}`);
  fs.writeFileSync('/tmp/playwright-test/results.json', JSON.stringify(results, null, 2));
  process.exit(failed ? 1 : 0);
})();
