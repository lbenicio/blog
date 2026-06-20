---
title: "Content Delivery Networks: DNS-Based Routing, Anycast, Edge Caching, and the Economics of CDN Peering"
description: "How Akamai, Cloudflare, and Fastly keep the web fast — DNS-based request routing, anycast IPs, consistent hashing at the edge, and the business of CDN peering that makes it all economically viable."
date: "2026-03-04"
author: "Leonardo Benicio"
tags: ["cdn", "content-delivery-network", "dns", "anycast", "edge-caching", "akamai", "cloudflare", "fastly", "peering"]
categories: ["systems", "distributed-systems", "networking"]
draft: false
cover: "/static/images/blog/content-delivery-networks-dns-anycast-edge-caching.png"
coverAlt: "Diagram of CDN architecture showing DNS-based routing, anycast edge POPs, consistent hashing for cache distribution, and peering relationships"
---

When you type `www.example.com` into your browser and press Enter, a remarkable sequence of events unfolds in the ~200 milliseconds before the page renders. DNS resolves the name to an IP address. A TCP connection is established. TLS negotiates encryption. HTTP requests the page. And — often invisibly — a Content Delivery Network (CDN) serves the static assets (images, CSS, JavaScript) from a server physically close to you, not from the origin server that might be on another continent. This last step, the CDN, is the reason the web feels fast despite the physics of long-distance fiber. And it represents one of the largest, most sophisticated distributed systems ever built.

CDNs handle an estimated 70-80% of all internet traffic by volume (dominated by video). The largest CDN — Akamai — has over 300,000 servers in 135 countries and serves 15-30% of all web traffic. Cloudflare, the upstart that challenged Akamai's dominance, has over 300 data centers (Points of Presence, PoPs) and serves ~20% of the top 10 million websites. Fastly, the developer-focused CDN, differentiates on real-time cache purging (<150 ms global purge) and edge computing (WebAssembly on the edge). Together, they form the invisible infrastructure that makes the modern web possible.

This post is a deep dive into CDN architecture: DNS-based request routing, anycast IPs, edge caching hierarchies, consistent hashing at the edge, and the economics of peering that make CDNs profitable despite razor-thin margins.

## 1. DNS-Based Request Routing

The first problem a CDN must solve is: given a request for `cdn.example.com`, which edge server should serve it? The answer is typically the server that is "closest" to the user in terms of network latency. But "closest" is not simply geographic distance — it depends on BGP routing, peering arrangements, and the current load on each PoP.

The standard technique is DNS-based request routing:

1. The user's browser requests `cdn.example.com` from its local DNS resolver.
2. The resolver eventually queries the authoritative DNS server for `cdn.example.com`, which is operated by the CDN.
3. The CDN's DNS server receives the query and sees the IP address of the resolver (not the end user, but typically close enough for routing purposes).
4. The DNS server consults a "map" — a database that maps resolver IP prefixes to the optimal edge PoP, computed from BGP routing tables, latency measurements, and PoP health/load.
5. The DNS server returns the IP address of the optimal PoP, with a short TTL (typically 30-300 seconds) so that the mapping can be changed quickly if the PoP fails or becomes overloaded.

The DNS-based approach has a fundamental limitation: the CDN sees the resolver's IP, not the user's. If a user in Mumbai uses a public DNS resolver (like Google's 8.8.8.8, which is anycast and may resolve from a different location), the CDN may route them to a suboptimal PoP. The EDNS0 Client Subnet extension (RFC 7871) allows the resolver to forward a portion of the user's IP to the authoritative DNS server, improving routing accuracy, but adoption is mixed due to privacy concerns.

## 2. Anycast: One IP, Many Locations

Anycast is a network addressing technique where the same IP address is announced from multiple locations via BGP. When a router receives multiple BGP advertisements for the same IP prefix, it chooses the "best" one (according to BGP path selection — typically the one with the shortest AS path or the highest local preference). This means that a packet sent to an anycast IP is automatically routed to the "closest" instance.

CDNs use anycast extensively. Cloudflare, for example, announces its IP ranges from every one of its 300+ PoPs. A user in Tokyo sending a packet to a Cloudflare IP will be routed to the Tokyo PoP (or the nearest one that is online), without any DNS trickery. Anycast provides automatic failover: if a PoP goes offline, BGP withdraws its route advertisement, and traffic automatically shifts to the next-closest PoP within seconds to minutes (depending on BGP convergence time).

Anycast has limitations:

- **Stateful connections.** If a PoP fails mid-connection, the TCP session breaks (the new PoP doesn't have the connection state) and the user must reconnect.
- **Uneven load distribution.** BGP does not consider server load — it routes based on AS path length, not CPU utilization. A PoP may be overloaded even though it is the "closest" by BGP metrics.
- **BGP convergence time.** It can take minutes for all routers on the internet to converge on a new route after a PoP failure.

## 3. Edge Caching Hierarchies

A CDN's core function is caching: storing copies of content close to users to reduce latency and origin server load. The caching architecture typically has two tiers:

**Edge cache (leaf nodes).** The servers that directly serve user requests. They cache hot content (frequently requested objects) in memory (RAM or SSD) and evict cold content using an LRU (Least Recently Used) or LFU (Least Frequently Used) algorithm. The edge cache has limited capacity (typically a few terabytes per server) but very low latency (<1 ms to serve a cached object).

**Parent cache (mid-tier).** A layer between the edge and the origin. If an edge cache misses, it requests the object from a parent cache rather than going all the way to the origin. The parent cache aggregates requests from many edge caches, increasing the cache hit rate for moderately popular content. This is called a "cache hierarchy" and it reduces origin load by orders of magnitude.

**Consistent hashing** is used to distribute objects across edge caches within a PoP. Rather than having every edge server cache every object (which would waste capacity), the CDN assigns each object to a specific cache server based on a hash of the object's URL. Consistent hashing ensures that when a cache server is added or removed, only O(K/N) objects are reassigned (where K is the number of objects and N is the number of servers), minimizing cache disruption.

## 4. Akamai vs. Cloudflare vs. Fastly

The three leading CDNs exemplify different architectural philosophies:

**Akamai** (founded 1998) is the original CDN, built for scale and reliability. Its architecture is hierarchical: edge servers, regional clusters, and a global overlay network. Akamai's key innovation was its "intelligent platform" — a distributed system that continuously measures latency, throughput, and packet loss between every pair of servers, and uses this data to make routing and caching decisions. Akamai excels at large-file delivery (video, software downloads) and has deep integrations with enterprise customers (its "EdgeCompute" platform runs customer code on Akamai's servers).

**Cloudflare** (founded 2009) disrupted the CDN market with a simple value proposition: free CDN for small websites, paid plans for enterprises. Cloudflare's architecture is anycast-based, with every PoP capable of serving every service (CDN, DDoS protection, DNS, Workers). This "every PoP does everything" model simplifies operations and reduces latency (no cross-PoP dependencies). Cloudflare's "Workers" platform (serverless functions at the edge) is its key differentiator: developers can deploy JavaScript/WASM code to all 300+ PoPs in seconds.

**Fastly** (founded 2011) targets developers who need real-time control. Its key differentiator is "instant purge": cache invalidation across the global network in <150 ms, compared to 5-15 seconds for most CDNs. Fastly achieves this by separating the control plane (cache configuration) from the data plane (serving requests), and using a purpose-built distributed key-value store (not consistent hashing) that propagates purges in real time. Fastly also pioneered edge computing with its "Compute@Edge" platform (WebAssembly on the edge, now rebranded as "Fastly Compute").

## 5. The Economics of CDN Peering

CDNs operate on razor-thin margins. The cost of bandwidth — what a CDN pays to transit providers (Tier 1 ISPs) and to peer with access networks — is their largest expense. To minimize this, CDNs engage in aggressive peering:

**Private peering.** The CDN connects its routers directly to the routers of major ISPs (Comcast, AT&T, Verizon, Deutsche Telekom) at internet exchange points (IXPs). This eliminates the transit provider (and its fees) and reduces latency by one network hop. Akamai has over 3,000 private peering sessions; Cloudflare has over 12,000.

**Settlement-free peering.** CDNs peer with ISPs on a "settlement-free" basis: neither pays the other, because the traffic exchange is roughly balanced or mutually beneficial (the ISP's customers want the CDN's content, and the ISP saves transit costs by peering directly).

**Embedded CDN.** Akamai and Netflix take this a step further: they place cache servers inside ISP networks (in the ISP's data centers, connected directly to the ISP's routers). This reduces latency to single-digit milliseconds and eliminates all transit costs for traffic served from those caches. Netflix's Open Connect program is the most prominent example: Netflix provides ISPs with pre-configured cache appliances, and in exchange, the ISP hosts them for free (because it saves them transit costs).

The economics of CDN peering are a case study in how infrastructure scale creates a competitive moat. A CDN with 10,000 peering connections can deliver content at lower cost and lower latency than a CDN with 100 peering connections, because it pays less for transit and has shorter paths to users. This is why the CDN market has consolidated around a few large players, and why new entrants (like Fastly) must differentiate on features (instant purge, edge compute) rather than on cost or coverage.

## 6. Cache Invalidation and Purging: The Hardest Problem in CDNs

There are only two hard problems in computer science: cache invalidation and naming things. For CDNs, cache invalidation is not a joke — it is the central operational challenge. When a content publisher updates an image, a CSS file, or a video, the old cached copies at hundreds of edge PoPs must be purged and replaced with the new version. The speed at which this happens determines how quickly users see the update.

The naive approach — pushing the new content to every edge server — does not scale (300,000 servers × millions of objects = combinatorial explosion). Instead, CDNs use one of two strategies:

**TTL-based expiration (time-to-live).** Every cached object has a TTL, set by the origin server via the `Cache-Control: max-age` HTTP header. When the TTL expires, the edge server must revalidate the object with the origin (using `If-Modified-Since` or `If-None-Match` conditional requests). This is simple and scalable, but the publisher has no control over exactly when the old content is evicted — the TTL is a maximum, not a guarantee. A publisher who wants to update content immediately must set a short TTL (increasing origin load) or use an explicit purge mechanism.

**Explicit purge.** The publisher sends a purge request to the CDN's API: "invalidate `/images/logo.png` on all PoPs." The CDN propagates the purge to all edge servers. The propagation latency — the time from purge request to the last edge server evicting the old content — is the key metric. Akamai's purge latency is typically 5-15 seconds. Cloudflare's is similar, though Cloudflare's "Cache Purge" API can target individual URLs or entire cache tags. Fastly's "instant purge" (<150 ms) is the fastest in the industry, achieved through a purpose-built distributed key-value store that propagates purge messages out-of-band from the HTTP data path.

**Surrogate keys (cache tags).** Rather than purging individual URLs, the publisher tags cached objects with semantic labels (e.g., `article-1234`, `author-leonardo`, `category-systems`). A single purge request can invalidate all objects with a given tag. This is especially useful for content management systems where updating a single entity (an author's biography) should invalidate all pages that include it. Fastly popularized surrogate keys, and Cloudflare and Akamai have since adopted similar mechanisms.

## 7. DDoS Protection and CDNs

CDNs are the first line of defense against Distributed Denial of Service (DDoS) attacks. Because a CDN sits between the user and the origin server, it can absorb attack traffic at its edge PoPs and prevent it from reaching the origin. This is a core value proposition of Cloudflare, which built its business on DDoS protection before expanding into CDN and edge computing.

The key DDoS mitigation techniques deployed at CDN edges:

**Anycast-based traffic distribution.** Because the CDN's IPs are announced via anycast from hundreds of PoPs, a volumetric DDoS attack (flooding the target with traffic) is automatically distributed across all PoPs. A 1 Tbps attack spread across 300 PoPs is only 3.3 Gbps per PoP — manageable for a well-provisioned edge server. The origin server, by contrast, is a single point that can be overwhelmed by a fraction of that traffic.

**Layer 3/4 filtering.** The CDN drops packets at the network edge based on IP reputation, protocol anomalies (e.g., SYN floods, UDP amplification), and rate limiting. Cloudflare's "Magic Transit" product extends this to protect entire IP ranges, not just HTTP traffic.

**Layer 7 filtering.** The CDN inspects HTTP requests and drops those that match attack patterns: excessive requests to a single URL, requests with malicious payloads (SQL injection, XSS), requests from known botnets. Cloudflare's Web Application Firewall (WAF) uses a combination of rule-based and machine-learning-based detection.

**Challenge-based authentication.** When a request is suspicious but not definitively malicious, the CDN can issue a JavaScript challenge (Cloudflare's "JS Challenge") or a CAPTCHA. Legitimate browsers execute the JavaScript automatically (which proves they are real browsers, not simple scripts) and are allowed through. Bots that cannot execute JavaScript are blocked.

## 8. Summary

CDNs are the invisible infrastructure of the modern internet. They serve the static assets that make websites fast, the video streams that dominate internet traffic, and the DDoS protection that keeps websites online under attack. Their architecture — DNS routing, anycast IPs, caching hierarchies, consistent hashing — is a masterclass in building distributed systems at global scale.

The CDN market is maturing, but innovation continues: serverless edge computing (Cloudflare Workers, Fastly Compute), real-time cache purging, and AI/ML-driven cache prefetching are active areas of development. The trend toward edge computing — moving computation, not just content, closer to users — is blurring the line between CDNs and cloud platforms. The CDN of the future may look more like a distributed operating system than a caching proxy, and that future is already being built.

## 9. The Future of CDNs: AI-Driven Caching and Edge Compute Convergence

The CDN market is evolving rapidly. Several trends are reshaping the architecture of CDNs:

**AI/ML-driven cache prefetching.** Traditional CDNs are reactive: they cache content when it is requested. AI-driven CDNs can be proactive: they predict which content will be popular (based on historical access patterns, social media trends, time of day) and pre-warm the cache before the requests arrive. This is especially valuable for live events (the Super Bowl, the World Cup) where demand spikes are predictable but enormous. Akamai and Cloudflare are both investing in ML-driven caching, using time-series forecasting models trained on their global traffic data.

**Edge computing convergence.** CDNs are becoming edge computing platforms. Cloudflare Workers, Fastly Compute, and Akamai EdgeWorkers allow developers to run serverless functions at CDN edge PoPs — not just serving cached content, but executing application logic at the edge. This blurs the line between CDN and cloud: the CDN edge becomes a globally distributed execution environment for latency-sensitive application code. A user request can be handled entirely at the edge — authenticated, authorized, data fetched from an edge database (like Cloudflare's Durable Objects), a response rendered — without ever touching the origin server.

**HTTP/3 and QUIC.** CDNs have been early adopters of QUIC and HTTP/3. Cloudflare and Google have supported QUIC on their edge since 2018 (before HTTP/3 was standardized), and the majority of CDN traffic now uses QUIC. QUIC's 0-RTT handshake is especially valuable for CDNs: a user requesting a cached asset can receive it in a single round trip (the QUIC Client Hello includes the HTTP request), compared to 2-3 round trips for TCP+TLS+HTTP. This reduces page load times by 10-30% for CDN-cached content.

**CDN peering wars.** The CDN market is consolidating, and the battleground is peering. The CDN with the most peering connections can deliver content at the lowest latency and lowest cost, creating a competitive moat. Cloudflare's aggressive peering strategy (12,000+ peering sessions) has been a key factor in its growth from startup to competitor to Akamai. Fastly's strategy is different: fewer peering connections but deeper integration with key ISPs and content providers (Fastly powers the edge for Shopify, Stripe, and The New York Times, among others).

## 10. Summary (Extended)

CDNs are the invisible infrastructure that makes the modern internet feel fast. They absorb DDoS attacks, cache content at the edge, route users to the nearest PoP, and increasingly execute application logic at the edge. Their architecture — DNS routing, anycast, caching hierarchies, consistent hashing — is a masterclass in distributed systems engineering at global scale.

The future of CDNs is convergence with edge computing: the CDN edge becomes a globally distributed application platform, running not just cached content but also serverless functions, databases, and AI inference. This convergence will blur the boundary between CDN and cloud, creating a new category: the "edge cloud," where computation happens at the point of presence closest to the user, under the same infrastructure that delivers the static assets of the web.

## 11. CDN Performance Measurement and Optimization

Measuring CDN performance is a surprisingly nuanced problem. The user's experience of a CDN depends on many factors: DNS resolution time, TCP/TLS handshake time, time-to-first-byte, download throughput, and cache hit rate. CDN operators and their customers use several measurement techniques:

**Real User Monitoring (RUM).** JavaScript injected into web pages reports actual user experiences: page load time, DNS lookup time, TCP connect time, TLS handshake time, time to first byte, and download time. RUM data provides ground truth about the user experience but is biased toward the users who visit the site (which may not be representative of the internet as a whole).

**Synthetic monitoring.** Probes deployed around the world (by companies like Catchpoint, ThousandEyes, and Pingdom) periodically fetch test objects from the CDN and measure performance. Synthetic monitoring provides a consistent, comparable view across geographies and time but may not reflect real user behavior (probes are on high-quality connections, not congested mobile networks).

**CDN performance benchmarks.** Independent benchmarks (like Cedexis, now part of Citrix, and the annual CDN performance reports) compare CDNs on latency, throughput, and availability across regions. These benchmarks reveal that no single CDN is fastest everywhere: Cloudflare may be fastest in North America, Akamai in Europe, Fastly in Asia-Pacific. This is why large content providers often multi-home — using multiple CDNs and routing users to the best-performing one for their location.

**The multi-CDN strategy.** Large content providers (Netflix, Facebook, Amazon) do not rely on a single CDN. They use multiple CDNs (Akamai + Cloudflare + Fastly) or their own CDN (Netflix Open Connect, Google Global Cache) and dynamically select the best CDN for each user based on real-time performance measurements. This is "intelligent DNS" — the DNS server returns different CDN IPs based on the user's location, the CDNs' current performance, and the cost of each CDN. Multi-CDN strategies increase complexity but improve reliability (if one CDN fails, traffic shifts to another) and performance (you can always route to the fastest CDN for each user).

## 12. Final Thoughts

CDNs are one of the unsung heroes of the internet. They operate at a scale — hundreds of thousands of servers, terabits per second of traffic, billions of users — that few other distributed systems can match. Their architecture — DNS routing, anycast, caching hierarchies, consistent hashing — has proven remarkably durable, surviving the transition from static websites to dynamic web applications, from Flash video to HTML5 streaming, from IPv4 to IPv6.

The CDN industry is not standing still. The convergence with edge computing (serverless at the edge), the adoption of new protocols (QUIC, HTTP/3), and the application of ML to caching and routing are transforming CDNs from content delivery platforms into distributed application platforms. The CDN of 2035 will likely be unrecognizable to an Akamai engineer from 2005 — and yet, the core ideas (get content close to users, route around failures, cache strategically) will remain the same.

## 13. The Economics of Free CDNs: How Cloudflare Disrupted the Market

Cloudflare's "free CDN" offering (launched in 2011) was a disruptive innovation that reshaped the CDN market. Before Cloudflare, CDNs charged based on bandwidth (dollars per GB served). Cloudflare gave away CDN services for free to small websites and charged enterprises on a tiered subscription model (based on features, not bandwidth). This was possible because:

**Economies of scale in peering.** Cloudflare's massive scale (millions of websites) gave it leverage in peering negotiations: ISPs wanted to peer with Cloudflare because Cloudflare's traffic was valuable to the ISP's customers. Settlement-free peering reduced Cloudflare's bandwidth costs to nearly zero for traffic served from its edge.

**Freemium as customer acquisition.** The free tier was a customer acquisition funnel: small websites grew, needed more features (DDoS protection, WAF, load balancing), and converted to paid plans. The cost of serving free customers was essentially the customer acquisition cost for paid customers.

**Cross-subsidization.** Cloudflare's high-margin enterprise products (DDoS protection, WAF, Spectrum, Magic Transit) subsidized the low-margin free CDN. The CDN was a loss leader that brought customers into the ecosystem.

Cloudflare's strategy worked spectacularly: from 2011 to 2025, it grew from a startup to a $50B+ public company, serving ~20% of the top 10 million websites. The strategy also forced Akamai and Fastly to respond with their own free/cheap tiers (Akamai's "Adaptive Media Delivery" and Fastly's "Developer Tier"). The CDN market, once a sleepy oligopoly of Akamai and a few others, is now fiercely competitive, with innovation driven by Cloudflare's relentless focus on developer experience and ease of use.

## 14. Final Thoughts

CDNs are the invisible infrastructure that makes the web fast, reliable, and secure. Their architecture — DNS routing, anycast, caching hierarchies, consistent hashing — is a masterclass in distributed systems design. Their evolution — from simple caching proxies to full-featured edge computing platforms — reflects the broader trend of computation moving closer to the user.

The CDN industry is not done innovating. The convergence with edge computing, the adoption of new protocols (QUIC, HTTP/3), the application of ML to caching and routing, and the intensifying competition among Cloudflare, Akamai, Fastly, and the cloud providers' own CDN offerings (AWS CloudFront, Azure CDN, Google Cloud CDN) — all point to a future where CDNs are not just content delivery networks but distributed application platforms, running the logic of the web at the edge, close to every user on the planet.

## 15. The History of CDNs: Lessons from Two Decades of Evolution

The CDN industry has evolved through several distinct phases, each teaching lessons about how distributed systems grow and compete:

**Phase 1 (1998-2005): The Akamai monopoly.** Akamai invented the CDN category, built a global network of edge servers, and enjoyed a near-monopoly. The lesson: first-mover advantage in distributed infrastructure is enormous because the capex and peering relationships create a barrier to entry that is hard to overcome.

**Phase 2 (2005-2015): Competition and commoditization.** Limelight, EdgeCast, Level 3, and others entered the market, driving down prices and forcing innovation. The lesson: infrastructure businesses with high fixed costs and low marginal costs (like CDNs) tend toward price competition unless they differentiate on features.

**Phase 3 (2010-2020): The Cloudflare disruption.** Cloudflare entered the market with a free tier, a developer-first ethos, and a product strategy that bundled CDN with DDoS protection, DNS, and eventually serverless computing. The lesson: a new entrant can disrupt an incumbent by changing the basis of competition — from price-per-GB to features and developer experience.

**Phase 4 (2020-present): Edge computing convergence.** CDNs are becoming edge computing platforms, and cloud providers are becoming CDNs (AWS CloudFront, Azure CDN, Google Cloud CDN). The lesson: infrastructure categories are converging. The CDN of the future will be indistinguishable from the edge cloud of the future — a globally distributed platform for running applications, not just serving content.

## 16. Final Summary

CDNs are among the most impressive distributed systems ever built — handling terabits per second of traffic, serving billions of users, absorbing the largest DDoS attacks in history, and doing it all with latencies measured in milliseconds. Their architecture combines ideas from networking (DNS, anycast, BGP), distributed systems (consistent hashing, caching hierarchies), and business strategy (peering, freemium pricing, product bundling). Understanding CDNs is essential for any systems engineer who builds applications at internet scale.

## 17. CDN Interconnection and the Future of Internet Architecture

CDNs are increasingly interconnected — not just peering with ISPs but peering with each other. The IETF's CDNI (Content Delivery Network Interconnection) working group has standardized interfaces for CDNs to share content, redirect requests, and account for costs. A small CDN (like a regional ISP's CDN) can use CDNI to acquire content from a large CDN (like Akamai or Cloudflare), extending its reach without building its own global infrastructure.

CDNI represents a vision of the internet where content is a shared, federated resource — not locked into a single CDN's infrastructure but accessible through any CDN that participates in the federation. This vision aligns with the internet's architectural principles (decentralization, interoperability, open standards) and stands in contrast to the walled-garden model of some content platforms (where content is only accessible through the platform's own CDN and apps).

The future of CDN interconnection may blur the boundary between CDNs and ISPs: if every ISP runs a CDN edge cache (as many already do, via Netflix Open Connect, Google Global Cache, and Akamai AANP), and if these caches are interconnected via CDNI, the result is a global, federated content distribution fabric — a "content internet" layered on top of the packet internet. This is the logical endpoint of the CDN evolution: not a service you buy, but a property of the network itself.

## 18. Concluding Remarks

CDNs are among the most impressive distributed systems ever built. They operate at a scale — millions of servers, terabits per second, billions of users — that few other systems can match. Their architecture combines ideas from networking, distributed systems, and business strategy in a way that is uniquely elegant and uniquely practical. Understanding CDNs — their routing, caching, peering, and economics — is essential for any engineer who builds systems at internet scale. The CDN is the invisible infrastructure of the web, and mastering it is mastering a core discipline of modern systems engineering.

## 19. Epilogue: The Speed of the Web

Content delivery networks are the reason the web feels fast. They cache content at the edge, route users to the nearest server, absorb DDoS attacks, and increasingly execute application logic at the point of presence closest to the user. Their architecture — DNS routing, anycast, caching hierarchies, consistent hashing — is a masterclass in distributed systems engineering. And their evolution — from simple caching proxies to full-featured edge computing platforms — reflects the broader trend of computation moving closer to the user. The CDN is the invisible infrastructure of the modern internet, and understanding it is understanding how the web works at scale.

## 20. Afterword: The Edge is the New Core

CDNs have become so essential to the internet that they are effectively part of its core infrastructure. A website that is not behind a CDN is slow, vulnerable to DDoS, and inaccessible from parts of the world with poor connectivity to its origin server. CDNs have moved from optional optimization to mandatory infrastructure. And as they evolve from caching proxies to edge computing platforms, they are becoming something even more fundamental: the distributed execution environment for the next generation of internet applications. The CDN is the edge. The edge is the new core. And the engineers who understand how CDNs work — their routing, caching, peering, and economics — are the ones who will build the internet of tomorrow.

## 21. Coda: The CDN as a Mirror of the Internet

A CDN is a mirror of the internet — a reflection of its topology, its economics, and its power structures. The CDN's PoP locations reflect the geography of internet users (dense in North America, Europe, and East Asia; sparse in Africa and South America). The CDN's peering relationships reflect the economics of internet connectivity (settlement-free where traffic is balanced, paid transit where it is not). And the CDN's control over content delivery reflects a concentration of power — a handful of CDNs control the delivery of the majority of the world's web traffic. Understanding CDNs is not just understanding a technology. It is understanding the internet itself — its geography, its economics, its power dynamics. The CDN is a mirror. Look into it, and you see the internet as it really is.

The CDN story continues. As CDNs evolve into edge computing platforms, as they adopt new protocols (QUIC, HTTP/3) and new techniques (ML-driven caching, real-time purge), they are becoming something more than content delivery networks. They are becoming the distributed operating system of the internet — a platform for running applications at the edge, close to every user, with the performance, reliability, and security that modern applications demand. The CDN is dead. Long live the CDN.

Content delivery networks are not just a service you buy. They are a fundamental layer of the internet stack — as essential as DNS, as pervasive as BGP, as invisible as the fiber in the ground. They make the web fast, reliable, and secure. They absorb attacks, cache content, and route users to the optimal server. And increasingly, they execute application logic at the edge. The CDN is no longer just a content delivery network. It is the platform on which the next generation of internet applications will be built.

CDNs are the unsung heroes of the internet age. They make websites fast, videos smooth, and applications responsive — for billions of users, across every continent, at every moment. They do this through a combination of clever architecture (DNS routing, anycast, caching hierarchies), sophisticated algorithms (consistent hashing, cache eviction, traffic engineering), and relentless operational excellence (peering, monitoring, DDoS mitigation). The CDN is a distributed system of staggering scale and remarkable reliability. It deserves to be understood, appreciated, and studied by every engineer who builds for the internet.
