# Free-tier relay

The Mac app and native file tools work without a Cloudflare account. Phone pairing is optional. The configured Worker uses Cloudflare Workers Free and one D1 database; it does not require a paid model API, R2, or a custom domain.

## Kio's bounds

- At most 5 new Kio workspaces per source IP per UTC day. The relay stores a SHA-256 hash of the IP for the two-day rate-limit window; it does not store the raw IP in D1.
- At most 12 encrypted file uploads per paired device per hour.
- At most 50 MiB per file and 64 MiB of active transfer data per workspace.
- A 384 MiB global active-transfer ceiling leaves room for D1 rows and metadata within the Free database's 500 MB per-database limit.
- Message envelopes and transfers expire after 24 hours. Acknowledgements delete them sooner. Expired pairings, rate-limit rows, and revoked phone records are cleaned up.

The limits are enforced in D1 as well as in request preflight checks. Rejected uploads return a capacity or rate-limit error; they do not silently consume another workspace's allowance. Revoked/expired device credentials are not used to read queued data.

## Cloudflare's published Free limits

Cloudflare currently lists 100,000 Worker requests per day, 10 ms CPU per invocation, 5 million D1 rows read per day, 100,000 D1 rows written per day, and 500 MB per D1 database. Exceeding the daily D1 read/write quotas causes D1 queries to fail until the quota resets; Kio returns a specific retry-after-midnight message for those D1 errors. Cloudflare can change these limits; review the official [Workers limits](https://developers.cloudflare.com/workers/platform/limits/), [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/), and [D1 limits](https://developers.cloudflare.com/d1/platform/limits/) before deploying.

The 384 MiB active transfer ceiling is a Kio safety margin, not a billing allowance. If a free service limit is reached, local Mac workflows remain usable without the relay.
