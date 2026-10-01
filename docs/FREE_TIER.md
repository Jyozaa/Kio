# Free-tier relay

Kio's mandatory recurring cost is £0. The Mac app, local model, and native file tools work without a Cloudflare account. Phone pairing is optional. The configured Worker uses the Cloudflare Workers Free and D1 architecture; it does not require a paid model API, R2, or a custom domain. Cloudflare can change its free-plan quotas, so verify the provider limits before deployment.

## Kio's bounds

- At most 5 new Kio workspaces per source IP per UTC day. The relay stores a SHA-256 hash of the IP for the two-day rate-limit window; it does not store the raw IP in D1.
- At most 12 encrypted file uploads per paired device per hour.
- At most 50 MiB per file and 64 MiB of active transfer data per workspace.
- A 384 MiB global active-transfer ceiling leaves room for D1 rows and metadata within the Free database's 500 MB per-database limit.
- Message envelopes and transfers expire after 24 hours. Acknowledgements delete them sooner. Expired pairings, rate-limit rows, and revoked phone records are cleaned up.

The limits are enforced in D1 as well as in request preflight checks. Rejected uploads return a capacity or rate-limit error; they do not silently consume another workspace's allowance. Revoked/expired device credentials are not used to read queued data.

## Provider limits

Kio's enforced bounds do not guarantee that Cloudflare's separate service quotas will be available. Review the official [Workers limits](https://developers.cloudflare.com/workers/platform/limits/), [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/), and [D1 limits](https://developers.cloudflare.com/d1/platform/limits/) before deploying. If a free service limit is reached, local Mac workflows remain usable without the relay.

The 384 MiB active transfer ceiling is a Kio safety margin, not a billing allowance.
