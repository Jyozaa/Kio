# Free-tier relay

The Mac app and its file tools work locally without a Cloudflare account. Phone pairing is optional. The Worker is configured for Cloudflare's free Workers plan and uses a single free D1 database for device, queue, and encrypted-file data; it does not require a custom domain, paid Workers, R2, or a model API.

Current published Workers Free limits include 100,000 Worker requests/day, 5 million D1 rows read/day, 100,000 rows written/day, and a 500 MB D1 database cap. On the Free plan, requests that exceed Workers, D1, or KV included quotas fail rather than becoming paid overage. Kio's own file bound is 50 MiB per transfer and 128 MiB of active file data total. Files are stored as encrypted 1,000,000-byte D1 chunks, deleted on recipient acknowledgement, or removed by a 15-minute cleanup trigger after 24 hours. D1 BLOB rows stay under Cloudflare's 2 MB row limit.

These limits are shared with other Workers resources in the same Cloudflare account. Free limits can change; review the current [Workers pricing and limits](https://developers.cloudflare.com/workers/platform/pricing/), [D1 limits](https://developers.cloudflare.com/d1/platform/limits/), and [D1 pricing](https://developers.cloudflare.com/d1/platform/pricing/) before deploying. If a required service begins asking to enable a paid plan, the local Mac product remains usable without it.
