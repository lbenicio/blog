---
title: "Teaching GraphQL to Cache at the Edge"
date: 2022-09-03T12:15:00Z
description: "A deep dive into making GraphQL play nicely with edge caches without breaking declarative APIs."
tags: ["graphql", "edge", "performance", "caching", "frontend"]
categories: ["Engineering"]
draft: false
cover: "static/images/blog/graphql-caching-edge-strategies.png"
coverAlt: "GraphQL query nodes flowing through edge cache layers"
---

GraphQL promises tailor-made responses, but tailor-made payloads resist caching. For years, we treated GraphQL responses as ephemeral: generated on demand, personalized, too unique to reuse. Then mobile latency complaints reached a boiling point. Edge locations sat underutilized while origin clusters sweated. We set out to teach GraphQL how to cache—respecting declarative queries, personalization boundaries, and real-time freshness. This is the story of building an edge caching layer that felt invisible to developers yet shaved hundreds of milliseconds off user interactions.

If you've ever been told "GraphQL can't cache," this post is for you. We'll explore schema annotations, persisted queries, cache keys, invalidation, and the human choreography required to make deductive caching decisions feel natural. Expect war stories: cache stampedes, stale user state, and the joy of a 95th percentile response that finally fits under 150 ms.

## 1. Why GraphQL resists caching

Traditional REST endpoints map one URL to one resource. Caches key off URLs easily. GraphQL collapses everything into a single endpoint, with queries describing desired fields. The same endpoint can produce vastly different responses per request. Personalized data (like user settings), fine-grained field selection, and mutations complicate caching. Developers often disable caching to avoid serving wrong data. Result: every query hits origin, even if thousands of users ask the same question.

We needed a strategy that respected GraphQL's flexibility while unlocking reuse. Our hypothesis: most queries have structure. With the right metadata and discipline, we can derive cacheable signatures.

## 2. Persisted queries and signatures

We started by adopting persisted queries. Clients register queries ahead of time, receiving a hash identifier. At runtime, clients send the hash and variables instead of raw query text. Persisted queries prevent injection attacks and standardize structure. They also produce stable signatures we can use for caching. We stored persisted query metadata in a schema registry, including cache hints like TTL and scope.

Each persisted query includes:

- Query hash (SHA-256).
- GraphQL document with field selections.
- Variable schema and allowed defaults.
- Cache policy annotation (discussed later).
- Tags indicating personalization requirements.

Runtime requests include the hash, variables, and authentication context. Edge caches reconstruct a cache key: `hash + normalized variables + user scope`. Normalization ensures variable ordering and default values don't produce different keys.

## 3. Cache policy annotations

We extended our GraphQL schema with directives, inspired by `@cacheControl` but richer. Example:

```graphql
type Query {
  product(id: ID!): Product @cacheable(ttl: 300, scope: PUBLIC, vary: ["locale", "currency"])
}

type Product {
  price(currency: Currency!): Money @cacheable(ttl: 120, scope: USER)
}
```

Directives describe caching intent:

- `ttl`: seconds to cache.
- `scope`: `PUBLIC`, `PRIVATE`, or `USER` (scoped to authenticated identity).
- `vary`: list of headers or variables affecting cache key.
- `invalidation` rules for downstream updates.

The schema registry compiles directives into metadata consumed by the edge layer. Developers think declaratively; the platform handles implementation.

## 4. Edge cache architecture

We deployed caching capabilities into our global edge network (based on Varnish and custom Lua). The flow:

1. Client sends persisted query hash and variables to edge.
2. Edge looks up query metadata.
3. Edge computes cache key, including scope tokens (e.g., user ID hashed into a token) and vary parameters.
4. On cache hit, edge returns stored response.
5. On miss, edge forwards request to origin GraphQL gateway.
6. Origin responds with data and cache metadata headers.
7. Edge stores response according to TTL and scope.

We partitioned caches by scope: public caches share across users; user-scoped caches store per-identity entries, with quotas to avoid unbounded growth. Edge nodes replicate metadata but not private responses.

## 5. Normalizing variables and responses

Cache keys must be deterministic. Variables include objects or arrays; we normalized them using canonical JSON serialization (sorted keys, trimmed whitespace). We rejected requests with unregistered variable shapes to prevent bypassing caching via shape drift.

Responses include timestamp fields and ephemeral IDs. To maximize cache hits, we taught the origin to omit volatile fields unless necessary. For fields requiring freshness (e.g., "time since last login"), we computed them client-side or via on-demand fragments.

## 6. Handling mutations and invalidation

Mutations change data and must invalidate caches. We built an invalidation bus. When a mutation commits, it emits events describing affected entities (e.g., Product 123). The cache layer subscribes to the bus and evicts relevant cache keys.

We map entities to queries via a dependency graph stored in Redis. When a persisted query runs, origin records which entities contributed to the response. Dependencies include entity IDs and field-level hints. The invalidation worker uses this map to evict precise cache entries. To avoid stale reads during propagation, we adopted write-through semantics: origins respond with updated payloads and include `Cache-Status: Bypass` headers, prompting edges to refresh entries.

## 7. Staleness and revalidation

Some data tolerates staleness. We implemented stale-while-revalidate (SWR). During TTL, cache returns responses immediately. After TTL but within `staleWindow`, edge serves stale response while asynchronously fetching fresh data. Developers configure these windows via directives. SWR improved tail latency and absorbed thundering herds during revalidation.

## 8. Personalization boundaries

Personalized data complicates caching. We categorized personalization:

- **Identity-based**: user profile info. Cache per user with small TTLs.
- **Segment-based**: locale, subscription tier, feature flags. We derived cache keys from segment tokens rather than raw attributes.
- **Opaque**: data unique per request (e.g., recommendations). We bypass caching.

We encouraged developers to factor queries into fragments: cacheable public data + personalized overlays fetched separately. This decomposition let us cache heavy public fragments while leaving private data dynamic.

## 9. Observability and metrics

We instrumented the cache layer with metrics:

- Hit/miss rates by query hash.
- Average TTL utilization.
- Invalidation latency from mutation to eviction.
- Cache size per scope and edge region.
- Origin offload percentage.
- Error rates when cache metadata missing or malformed.

Dashboards spotlight top misses, guiding optimization. We logged cache decision traces, letting developers debug why a request bypassed cache. Trace entries show hash, resolved key, TTL, scope, and invalidation watchers.

## 10. Developer workflow

Implementing caching required new workflows:

1. Design GraphQL schema with cache directives.
2. Register persisted query with metadata, including default variables.
3. Monitor observability dashboards after deployment.
4. Iterate: adjust TTLs, add vary dimensions, refactor fragments.

We built lint rules: queries lacking cache directives emit warnings. A CLI tool simulates requests, showing resolved cache keys and predicted hitability. Pull request templates prompt developers to declare caching decisions and invalidation strategy.

## 11. Edge logic implementation

Edge behavior runs in Lua. Snippet:

```lua
local metadata = get_query_metadata(hash)
if not metadata.cacheable then
  return fetch_origin()
end

local key = build_cache_key(hash, metadata, request)
local cached = cache_lookup(key)
if cached then
  return cached
end

local response = fetch_origin()
if response.cacheable then
  cache_store(key, response.body, metadata.ttl)
end
return response
```

We handle `stale-while-revalidate` by storing extra metadata alongside the payload and scheduling background refreshes via a lightweight job queue. Lua coroutines allow asynchronous fetches without blocking other requests.

## 12. Security and correctness

Caching introduces risks: leaking user data across tenants, serving stale authorization state. We mitigated by:

- Encrypting cache entries for user scope, with keys derived per tenant.
- Including authorization scopes in cache keys, so changes to permissions trigger cache misses.
- Validating that responses lack Set-Cookie or sensitive headers before caching.
- Running automated tests injecting tainted data to ensure isolation.

We also audited GraphQL resolvers to ensure `@cacheable(scope: PUBLIC)` annotations only appear on resolvers that never touch user-specific state.

## 13. Handling real-time data

Some GraphQL queries power real-time dashboards. For them, we combined caching with subscriptions. Base data loads from cache; overlays arrive via subscriptions. We tuned TTLs to seconds and used SWR to mask refresh jitter. For stock tickers, we kept caches disabled but optimized resolvers separately.

## 14. Cold start optimization

Edge nodes warm caches opportunistically. During deploys, we run prefetch jobs replaying popular queries through edges, priming caches. Prefetch uses safe credentials and respects rate limits. We also share cache digests across regions: when region A computes a new response, it publishes digest metadata. Regions B/C decide whether to fetch proactively based on popularity.

## 15. Handling GraphQL directives and fragments

Developers use conditional directives (`@include`, `@skip`). We encode directive outcomes into cache keys. For fragments, we compute structural hashes. This ensures different selections produce distinct cache keys even if they share base query hash.

## 16. Testing and validation

We expanded integration tests. Test suites run queries against a sandbox edge environment, asserting expected caching behavior. We built a "cache inspector" tool that visualizes dependency graphs, TTL countdowns, and invalidation triggers. QA uses the inspector to confirm correct behavior during feature rollouts.

## 17. Case study: product detail pages

Before caching, product pages fetched data via three GraphQL queries, totaling 450 ms median. After applying cache directives, persisted queries, and fragment decomposition, we achieved:

- 80% cache hit rate on public product data.
- 120 ms median response at the edge.
- 65% reduction in origin CPU load.

Observability also surfaced hidden dependencies. A marketing banner resolver pulled inventory counts indirectly, triggering invalidations every time stock refreshed. Once telemetry highlighted the culprit, we split the resolver into two persisted queries—one cache-friendly, one dynamic—restoring stability. The lesson: caching audits double as architecture reviews, exposing tight coupling masked by GraphQL's abstraction.

Invalidation triggered when merchants updated inventory. The dependency graph ensured targeted evictions, with average 1.8 seconds from mutation commit to cache purge. Users saw fresher data than before because origin computations no longer throttled under load.

## 18. Case study: user dashboards

Dashboards combined heavy analytics (public) with personalized summaries. We cached analytics fragments for 10 minutes. User-specific widgets fetched live data. Results: 45% latency reduction, but more importantly, developers embraced caching by default, adding directives as part of schema design.

Dashboards also benefited from network cost savings. Edge caches served 72% of total dashboard traffic, shrinking inter-region data transfer costs by five figures monthly. Product managers used the newfound slack to experiment with richer visualizations, confident that caches would shield origin layers. As we expanded internationally, localized dashboards reused cached global fragments, letting small regional teams launch new experiences without complex backend rewrites.

## 19. Failure modes

We hit bugs:

- Missing invalidation events left stale prices. We added replay queues and idempotent handlers.
- Cache stampedes when TTL expired simultaneously. SWR plus jittered TTL solved this.
- Oversized responses busted cache memory. We enforced payload size limits and encouraged field-level pagination.
- Hash collisions (extremely rare) triggered fallback to origin. We now check for collisions when registering persisted queries.

## 20. Metrics and dashboards that kept us honest

Caching success hinges on visibility. Our canonical dashboard includes:

- **Hit rate heatmap**: rows for services, columns for edge regions. Cells colored by hit rate with tooltips showing sample size. Outliers reveal misconfigured directives.
- **TTL utilization**: measures how long entries survive relative to configured TTL. Early evictions indicate invalidation churn; overlong survival suggests room to shorten TTL.
- **Origin offload**: charts request volume absorbed by caches. We compare to baseline weeks to quantify savings.
- **Staleness monitor**: tracks percentage of responses served from stale-while-revalidate along with latency impact. Spikes expose blocked revalidation jobs.
- **Error correlation**: overlays cache bypass reasons (auth mismatch, schema drift) with origin error rates, helping teams prioritize fixes.

Dashboards feed weekly reviews where teams annotate anomalies. We export snapshots for executive updates, translating cache metrics into revenue and latency language.

## 21. Operational runbook

We codified cache operations into a runbook:

1. **Incident triage**: confirm scope by checking hit rate heatmap and origin offload. If hit rates plummet across regions, suspect metadata outages.
2. **Invalidate safely**: prefer targeted invalidation via dependency graph. Only purge entire caches with VP approval; mass purges risk stampedes.
3. **Warm start**: after purges or deploys, trigger prefetch jobs for top queries using traffic recordings. Monitor CPU and bandwidth while warming.
4. **Measure blast radius**: use synthetic probes to simulate user flows during incidents, ensuring caches recover globally.
5. **Postmortem**: capture root causes, update directives or tooling, and add regression tests. Share learnings in the cache guild channel.

Runbooks live alongside playbooks for scaling, maintenance windows, and schema migrations. We rehearse quarterly with game days focusing on invalidation storms and edge outages.

## 22. Frequently asked questions

**"Does caching break GraphQL's flexibility?"** No—developers still compose fragments freely. Persisted queries cover 95% of traffic; dynamic queries fall back to origin with minimal overhead.

**"What about user-specific data?"** Cache scope handles it. User caches live in encrypted stores with tight TTLs and quotas. Truly unique responses bypass caching gracefully.

**"How do we prevent stale feature flags?"** Flags become part of vary parameters. When flag sets change, cache keys rotate automatically, forcing fresh fetches.

**"Is schema evolution painful?"** Schema registry enforces versioning. When fields deprecate, we maintain aliasing until caches expire. Migration guides outline safe rollout patterns.

**"Do we still need CDNs?"** Absolutely. Edge caching complements CDN delivery for static assets. In fact, we piggybacked on the CDN network to deploy our caching logic.

## 23. Migration timeline example

Our 12-month rollout followed phases:

- **Months 0–2**: build schema registry, define cache directives, implement persisted query infrastructure.
- **Months 2–4**: onboard search pages as pilot, tune invalidation bus, create dashboards.
- **Months 4–6**: expand to product detail and checkout flows, deliver developer training, integrate QA automation.
- **Months 6–9**: add personalization overlays, enforce lint rules, negotiate cache guardrails with security.
- **Months 9–12**: migrate long-tail services, optimize cost, formalize cache guild, and publish public post describing performance wins.

Pausing between phases allowed us to absorb feedback and iterate on tooling. Attempting a big-bang migration would have overwhelmed support teams.

## 24. Glossary for cache literacy

- **Cache scope**: level of sharing—public, private, user-specific—that determines key structure and storage location.
- **Cache stampede**: surge of requests when entries expire simultaneously, overwhelming origin.
- **Dependency graph**: mapping between backend entities and queries relying on them, used for precise invalidation.
- **Persisted query**: pre-registered GraphQL query identified by hash, enabling stable cache keys.
- **SWR (stale-while-revalidate)**: strategy serving stale data briefly while refreshing in background.

We plaster these definitions on dashboards and in onboarding decks to align vocabulary across frontend, backend, and platform teams.

## 25. Analytics and experimentation

Caching impacted experimentation. A/B tests rely on quick propagation of feature flags. We integrated experiment assignment into cache keys via vary parameters. Experiment frameworks emit metadata so caches respect segmentation. We created an "experiment-safe" directive ensuring TTLs align with experiment duration.

## 26. Developer education

We ran workshops titled "GraphQL Cache Literacy." Engineers practiced annotating schemas, analyzing traces, and debugging misses. We published a playbook with recipes: caching lists, nested resolvers, trending lists, personalization overlays. A dedicated Slack channel paired developers with caching experts for rapid feedback.

## 27. Business outcomes

Post-rollout metrics:

- 95th percentile latency for mobile product queries dropped from 620 ms to 210 ms.
- CDN egress decreased by 33%, saving costs.
- Origin cluster CPU utilization reduced by 48% during peak shopping season.
- Cache correctness incidents fell below 0.2 per month after initial shakedown.

Customer satisfaction surveys mentioned faster load times. Teams adopted caching for 70% of new queries within six months.

## 28. Future evolution

We're experimenting with edge compute that can execute lightweight GraphQL resolvers near users, further reducing origin dependency. We're also exploring signed exchange formats so caches can pre-validate responses. Another frontier is "privacy-aware caching" that integrates consent states into cache decisions to avoid storing responses for users opting out of personalization.

## 29. Toolchain sampler

- **Schema Registry UI** – browse persisted queries, inspect directives, and monitor TTL usage per field. Ships with diff views for schema changes.
- **Cache Inspector CLI** – run `cache-inspector trace <hash>` to visualize dependency graphs and cache decisions. Supports exporting mermaid diagrams for docs.
- **Invalidation Simulator** – replay mutation streams against staging caches to measure eviction accuracy before production rollouts.
- **Edge Dev Sandbox** – local Docker compose environment emulating edge Lua runtime, enabling developers to test logic without deploying globally.
- **Directive Linter** – ESLint plugin ensuring React components reference persisted queries with correct cache hints.

We maintain playbooks for each tool and host monthly office hours where teams share scripts that automate repetitive cache tasks.

## 30. Community and continued learning

We contribute to upstream projects like Apollo and GraphQL Foundation working groups. Our engineers present lessons at meetups under the banner "Caching the Uncacheable." Favorite resources include:

- **"Caching GraphQL at Scale" (GraphQL Conf 2022 talk)** – compares multiple industry approaches.
- **Apollo Router documentation** – rich examples for persisted queries and cache control.
- **"Stitching Edge and Origin" (CDN Summit 2023)** – explores edge compute patterns for GraphQL.
- **OpenTelemetry instrumentation recipes** – invaluable for embedding cache metadata into traces.

Sharing progress publicly keeps us accountable and attracts collaborators who push the ecosystem forward.

## 31. Conclusion

GraphQL and caching need not be enemies. By embracing declarative metadata, disciplined workflows, and robust invalidation, we transformed a dynamic API into a cache-friendly platform. The payoff was faster experiences and happier engineers. Teaching GraphQL to cache required patience, storytelling, and relentless measurement—but the lesson stuck. When teams now design queries, their first question is "how will this cache?"—proof that culture follows architecture.

### Further reading

- **"Cache Control for GraphQL" (Apollo blog)** – deep dive into schema directives and caching semantics.
- **"Designing Distributed Cache Invalidation" (USENIX ATC 2021)** – research perspective on dependency graphs.
- **"Edge Compute Patterns" (Cloudflare Developer Docs)** – practical recipes for executing logic at the edge.
- **"Experimentation with Cached APIs" (Shopify Engineering)** – lessons on keeping A/B tests statistically sound under caching.
- **GraphQL Foundation Working Groups** – community forums discussing standardization of cache metadata.

### Acknowledgements

Edge SREs, frontend engineers, and the schema governance crew co-authored these practices; their persistence turned skepticism into muscle memory.
