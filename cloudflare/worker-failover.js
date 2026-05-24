// Failover Worker: Pi cluster (Cloudflare Tunnel) → AWS CloudFront
// Deployed at cloudless.gr/* via Cloudflare Workers.
//
// Flow:
//   1. Rewrite host to pi-origin.cloudless.gr → routes through CF Tunnel → Pi Traefik :18443
//   2. On 5xx or network failure/timeout → fallback to AWS CloudFront (AWS_FALLBACK_HOST)
//
// Required Worker Variable (Cloudflare dashboard or wrangler.toml [vars]):
//   AWS_FALLBACK_HOST  e.g. d1234abcd.cloudfront.net
//
// Required repo secrets for deployment:
//   CLOUDFLARE_API_TOKEN  (Workers:Edit + Zone:DNS Read)
// Required repo variables:
//   CLOUDFLARE_ACCOUNT_ID
//   AWS_CLOUDFRONT_HOST

const PI_BACKEND = 'pi-origin.cloudless.gr';
const TIMEOUT_MS = 10000;

export default {
  async fetch(request, env) {
    // --- 1. Try Pi cluster via Cloudflare Tunnel backend ---
    const piUrl = new URL(request.url);
    piUrl.hostname = PI_BACKEND;

    try {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), TIMEOUT_MS);

      const piResp = await fetch(new Request(piUrl.toString(), {
        method: request.method,
        headers: request.headers,
        body: ['GET', 'HEAD'].includes(request.method) ? undefined : request.body,
        redirect: 'manual',
        signal: ctrl.signal,
      }));
      clearTimeout(timer);

      if (piResp.status < 500) {
        return new Response(piResp.body, {
          status: piResp.status,
          statusText: piResp.statusText,
          headers: piResp.headers,
        });
      }
      console.log(`Pi returned ${piResp.status} — failing over to AWS`);
    } catch (err) {
      console.log(`Pi unreachable (${err.message}) — failing over to AWS`);
    }

    // --- 2. Fallback: AWS CloudFront ---
    const awsUrl = new URL(request.url);
    awsUrl.hostname = env.AWS_FALLBACK_HOST;

    const awsResp = await fetch(new Request(awsUrl.toString(), {
      method: request.method,
      headers: request.headers,
      body: ['GET', 'HEAD'].includes(request.method) ? undefined : request.body,
      redirect: 'manual',
    }));

    const headers = new Headers(awsResp.headers);
    headers.set('X-Served-By', 'aws-fallback');
    return new Response(awsResp.body, {
      status: awsResp.status,
      statusText: awsResp.statusText,
      headers,
    });
  },
};
