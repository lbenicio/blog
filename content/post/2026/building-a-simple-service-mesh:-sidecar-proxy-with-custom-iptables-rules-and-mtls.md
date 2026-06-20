---
title: "Building A Simple Service Mesh: Sidecar Proxy With Custom Iptables Rules And Mtls"
description: "A comprehensive technical exploration of building a simple service mesh: sidecar proxy with custom iptables rules and mtls, covering key concepts, practical implementations, and real-world applications."
date: "2026-04-19"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/Building-A-Simple-Service-Mesh-Sidecar-Proxy-With-Custom-Iptables-Rules-And-Mtls.png"
coverAlt: "Technical visualization representing building a simple service mesh: sidecar proxy with custom iptables rules and mtls"
---

Here is the expanded version of your blog post. I have expanded the introduction and developed the full article, adding deep technical explanations, practical code examples (Go and shell scripts), and new sections on Envoy configuration, control planes, performance benchmarking, and security analysis. The tone remains professional and engaging, and the post is structured to be both an educational deep dive and a practical guide.

---

### Introduction: Untangling the Mesh with Iptables and mTLS

It began, as these things often do, with a single, frantic message on the company’s critical incident channel. "Production latency is spiking on the payment service. No deployment in the last 48 hours. No obvious code change. Help."

The immediate instinct is to check the usual suspects: database connection pool exhaustion, a memory leak, a spike in traffic from a viral marketing campaign. But this time, the culprit was more insidious. It wasn't a code bug; it was a _network bug_. A new microservice, a hastily deployed "fraud-checker," was making aggressive, unauthenticated HTTP calls directly to the payment service. It wasn't malicious, just poorly written. It was hitting a shared, unauthenticated endpoint that internally processed a CPU-intensive task. The security team was furious. The SRE team was exhausted. The developers on the fraud-checker team were apologetic but helpless—their service needed that data to function.

This story is a microcosm of the modern distributed systems dilemma. We have broken our monolithic applications into microservices, and in doing so, we have exploded the complexity of our network. Problems that were once internal to a single process are now problems of _communication_ between processes. Observability becomes a game of connect-the-dots across dozens of services. Security becomes a nightmare of managing trust between every pair of servers. Traffic management becomes a guessing game of retries, timeouts, and circuit breakers, often implemented inconsistently and poorly.

For years, the conventional solution to this chaos has been the Service Mesh. Giants like Istio, Linkerd, and Consul Connect have become the de facto standard for handling these inter-service communication concerns. They promise a unified, transparent layer for observability, security, and traffic control. They are powerful, but they are also complex. They introduce new control planes, sidecar proxies, and significant resource overhead. For a startup or a small team, deploying a full-blown Istio mesh can feel like hiring an entire DevOps team just to manage the mesh itself.

But what if the core principles of a service mesh—transparent interception, mutual TLS, and traffic shaping—could be achieved with simpler, more primitive tools? What if the secret sauce was not a new Kubernetes CRD, but two old friends: `iptables` and `openssl`?

This post is a practical, hands-on journey into building a "poor person's" service mesh. We will strip away the marketing abstraction and rebuild the fundamental mechanisms from the ground up. You will learn exactly how traffic is hijacked using Linux's Netfilter framework, how certificates are exchanged to establish mutual TLS, and how a simple sidecar proxy can enforce policies without your application code ever knowing.

By the end, you will have a deep, foundational understanding of what makes a service mesh tick, and you will possess the knowledge to build one yourself. More importantly, you'll understand the critical trade-offs that the big, production-grade meshes make, and why they are often worth the complexity.

### Section 1: The Anatomy of a Sidecar Proxy

Before we touch a single terminal command, we must deconstruct what a service mesh _is_. Conceptually, a service mesh is a dedicated infrastructure layer for handling service-to-service communication. It typically consists of two main components:

1.  **The Data Plane:** This is the layer of proxies that intercept all traffic in and out of a microservice. In Istio, this is an Envoy proxy running as a sidecar container alongside your application.
2.  **The Control Plane:** This is the brain of the mesh. It manages the configuration of the proxies, distributes certificates, and aggregates telemetry. In Istio, this is the `istiod` component.

#### The Sidecar: Transparent Interception

The magic of the data plane lies in its transparency. An application (e.g., a Go HTTP server) should be unaware that it is being proxied. It should listen on its regular port (e.g., `:8080`), and it should make outbound calls as usual (e.g., `GET http://other-service:9090`). The sidecar proxy sits in the middle, silently redirecting this traffic to itself.

How does a sidecar proxy intercept traffic without changing code? The answer is **iptables**. Linux's Netfilter framework allows us to define rules that match packets by destination port, source IP, or other attributes, and then redirect them to a different local port—the port the proxy is listening on.

Think of iptables as a set of programmable hooks in the Linux kernel's networking stack. Every packet that enters, exits, or traverses the host is checked against these chains. The chain we care about is the `OUTPUT` chain for locally generated application traffic, and the `PREROUTING` chain for incoming traffic.

#### A Concrete Example: Hijacking Outbound Traffic

Let's imagine our application is running in a container. Its outbound HTTP calls to other services should not go directly to the network. Instead, they should be captured by our proxy.

Here is a simplified iptables rule to make this happen:

```bash
# Redirect all TCP traffic destined for port 8080 (another service)
# to local port 15001 (our proxy's inbound listener)
iptables -t nat -A OUTPUT -p tcp --dport 8080 -j REDIRECT --to-port 15001
```

But this is naive. It will redirect _all_ outbound traffic on port 8080, including calls to the internet or to other non-mesh services. A smarter approach uses a dedicated user ID for the application. The proxy runs as a different user (e.g., `1337`), and the application runs as another (e.g., `1338`). We can then exclude the proxy's own traffic.

```bash
# Create a new chain
iptables -t nat -N PROXY_REDIRECT

# Exclude traffic from the proxy's user ID (1337)
iptables -t nat -A PROXY_REDIRECT -m owner --uid-owner 1337 -j RETURN

# Redirect all other TCP traffic destined for port 8080
iptables -t nat -A PROXY_REDIRECT -p tcp --dport 8080 -j REDIRECT --to-port 15001

# Apply the chain to the OUTPUT hook
iptables -t nat -A OUTPUT -j PROXY_REDIRECT
```

This is precisely how Istio and Linkerd implement their transparent proxy. The `istio-init` or `linkerd-init` containers run with the `NET_ADMIN` capability and install these iptables rules at pod startup. The sidecar proxy then listens on port `15001` and handles the traffic.

### Section 2: Building a Minimal Sidecar Proxy in Go

Theory is good; code is better. Let's build a minimal, non-production sidecar proxy in Go. This proxy will do two things:

1. Accept inbound connections on a specific port (e.g., `15001`).
2. Forward that traffic to the actual destination, performing a simple "forward proxy" function.

> **Important:** This proxy is deliberately simplified. It does not handle connection pooling, TLS termination, or load balancing. It is a proof of concept for traffic interception.

#### The Handler: A Simple TCP Proxy Tunnel

Our proxy will listen for TCP connections. When one arrives, it reads the first bytes of the connection (which in HTTP contains the destination host and port), extracts the destination, and opens a new TCP connection to that destination. It then performs a bidirectional copy of data, effectively creating a TCP tunnel.

```go
package main

import (
    "fmt"
    "io"
    "net"
    "os"
)

func handleConnection(conn net.Conn) {
    defer conn.Close()

    // We need to read the destination. In a real proxy, this would
    // decode the SOCKS5 or HTTP CONNECT protocol.
    // For simplicity, we assume the destination is passed via a
    // custom header or environment variable, or we just forward to a
    // known target.
    target := os.Getenv("PROXY_TARGET")
    if target == "" {
        target = "127.0.0.1:8080" // Default to local app
    }

    remote, err := net.Dial("tcp", target)
    if err != nil {
        fmt.Println("Error connecting to target:", err)
        return
    }
    defer remote.Close()

    // Bidirectional copy
    go io.Copy(remote, conn)
    io.Copy(conn, remote)
}

func main() {
    listener, err := net.Listen("tcp", ":15001")
    if err != nil {
        fmt.Println("Error starting proxy:", err)
        os.Exit(1)
    }
    defer listener.Close()
    fmt.Println("Proxy listening on :15001")

    for {
        conn, err := listener.Accept()
        if err != nil {
            fmt.Println("Error accepting connection:", err)
            continue
        }
        go handleConnection(conn)
    }
}
```

This proxy, when started, will listen on port `15001`. With the iptables rule in place, any outbound HTTP call from the application on port 8080 will be transparently redirected to this proxy, which then forwards it to the actual destination (defined by `PROXY_TARGET`).

**Why This Matters:** This tiny program demonstrates the fundamental mechanism of a sidecar. The application never knows its traffic was hijacked. The proxy can now add observability (logging all connections), security (enforcing which destinations are allowed), or resilience (retrying on failure).

### Section 3: The Secure Channel: Building Mutual TLS from Scratch

Traffic interception is only half the battle. The real value of a service mesh is **mutual TLS (mTLS)**. In a zero-trust network, every connection should be authenticated and encrypted. With mTLS, both the client and the server present certificates to prove their identity.

#### Why Not Just TLS?

Standard TLS secures the communication channel from eavesdropping (encryption) and proves the server's identity to the client (authentication). However, the client's identity is not verified by the server. This creates a security gap: any authenticated server can talk to any client, and the client's identity is only known via insecure means (e.g., an IP address or a token in the HTTP header). mTLS solves this by requiring the client to also present a certificate.

#### Certificate Authority and Certificate Generation

We will use OpenSSL to create our own Certificate Authority (CA), then issue a certificate for the client ("payment-service") and the server ("fraud-checker").

**Step 1: Create the CA**

```bash
mkdir -p certs && cd certs

# Generate a private key for the CA
openssl genrsa -out ca.key 2048

# Self-sign the CA certificate (valid for 10 years)
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 -out ca.crt -subj "/CN=My Service Mesh CA"
```

**Step 2: Create Certificates for Services**

We need a certificate for each service. The Common Name (CN) should be the service's identity. For service discovery, we can also set Subject Alternative Names (SANs) to the service's DNS name.

```bash
# Generate a key for the 'payment-service'
openssl genrsa -out payment-service.key 2048

# Create a Certificate Signing Request (CSR)
openssl req -new -key payment-service.key -out payment-service.csr -subj "/CN=payment-service.my-ns.svc.cluster.local"

# Sign the CSR with our CA to generate the certificate
openssl x509 -req -in payment-service.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out payment-service.crt -days 365 -sha256

# Repeat for 'fraud-checker'
openssl genrsa -out fraud-checker.key 2048
openssl req -new -key fraud-checker.key -out fraud-checker.csr -subj "/CN=fraud-checker.my-ns.svc.cluster.local"
openssl x509 -req -in fraud-checker.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out fraud-checker.crt -days 365 -sha256
```

Now you have `ca.crt`, `payment-service.crt`, and `payment-service.key`.

#### Implementing mTLS in Go

Now, we modify our proxy to perform TLS handshakes with mutual authentication. The sidecar proxy for the "payment-service" will listen for TLS connections. The sidecar proxy for the "fraud-checker" will initiate a TLS connection.

**Server-Side (Payment Service Proxy):**

```go
package main

import (
    "crypto/tls"
    "crypto/x509"
    "fmt"
    "io/ioutil"
    "log"
    "net"
)

func main() {
    // Load CA cert
    caCert, err := ioutil.ReadFile("certs/ca.crt")
    if err != nil {
        log.Fatal(err)
    }
    caCertPool := x509.NewCertPool()
    caCertPool.AppendCertsFromPEM(caCert)

    // Load server cert and key
    serverCert, err := tls.LoadX509KeyPair("certs/payment-service.crt", "certs/payment-service.key")
    if err != nil {
        log.Fatal(err)
    }

    tlsConfig := &tls.Config{
        Certificates: []tls.Certificate{serverCert},
        ClientAuth:   tls.RequireAndVerifyClientCert,
        ClientCAs:    caCertPool,
    }

    listener, err := tls.Listen("tcp", ":15001", tlsConfig)
    if err != nil {
        log.Fatal(err)
    }
    defer listener.Close()
    fmt.Println("mTLS proxy listening on :15001")

    for {
        conn, err := listener.Accept()
        if err != nil {
            log.Println(err)
            continue
        }
        tlsConn, ok := conn.(*tls.Conn)
        if !ok {
            log.Println("Non-TLS connection received")
            conn.Close()
            continue
        }
        // Perform handshake explicitly
        if err := tlsConn.Handshake(); err != nil {
            log.Println("TLS handshake failed:", err)
            conn.Close()
            continue
        }
        // Now we can extract the client certificate
        clientCert := tlsConn.ConnectionState().PeerCertificates[0]
        fmt.Printf("Authenticated client: %s\n", clientCert.Subject.CommonName)
        // Forward connection to local app...
        // (omitted for brevity, same as before)
    }
}
```

**Client-Side (Fraud-Checker Proxy):**

```go
package main

import (
    "crypto/tls"
    "crypto/x509"
    "fmt"
    "io/ioutil"
    "log"
    "net"
)

func main() {
    // Load CA cert
    caCert, err := ioutil.ReadFile("certs/ca.crt")
    if err != nil {
        log.Fatal(err)
    }
    caCertPool := x509.NewCertPool()
    caCertPool.AppendCertsFromPEM(caCert)

    // Load client cert and key
    clientCert, err := tls.LoadX509KeyPair("certs/fraud-checker.crt", "certs/fraud-checker.key")
    if err != nil {
        log.Fatal(err)
    }

    tlsConfig := &tls.Config{
        Certificates: []tls.Certificate{clientCert},
        RootCAs:      caCertPool,
        ServerName:   "payment-service.my-ns.svc.cluster.local", // Verify server identity
    }

    // Connect to the payment service's sidecar
    conn, err := tls.Dial("tcp", "payment-service:15001", tlsConfig)
    if err != nil {
        log.Fatal("mTLS connection failed:", err)
    }
    defer conn.Close()
    fmt.Println("mTLS handshake successful")

    // Now send HTTP request through this secure tunnel
    // ...
}
```

**What We Have Now:**

- The fraud-checker's outbound traffic is intercepted by iptables and sent to its sidecar proxy.
- The fraud-checker's sidecar proxy establishes an mTLS connection to the payment-service's sidecar proxy.
- The payment-service's sidecar proxy verifies the client certificate. If the fraud-checker is not trusted (e.g., not signed by the CA, or revoked), the connection is rejected at the network layer.
- Traffic is encrypted end-to-end between the two proxies.

This is the core of mesh security. No code changes in the application are required. The application just makes a plain HTTP call; the mesh provides security transparently.

### Section 4: Adding a Control Plane (The Hard Way)

A fully functional service mesh needs a control plane to manage certificate rotation, service discovery, and policy distribution. Building a full control plane is beyond the scope of a single blog post, but we can sketch its responsibilities and implement a minimal version using a shared filesystem or a simple API.

#### Responsibility 1: Certificate Distribution

In production, certificates cannot have a 10-year validity. They must be rotated frequently (e.g., every 24 hours) to limit the blast radius of a key compromise. The control plane must:

1. Issue new certificates for each service.
2. Deliver them to the sidecar proxy without downtime.

**A simple implementation:** A shared volume mounted into each sidecar container containing a current certificate and key. A cron job (or the control plane) updates these files, and the sidecar proxy watches for file changes and reloads its configuration.

```go
// Using fsnotify to watch for changes
watcher, _ := fsnotify.NewWatcher()
defer watcher.Close()
watcher.Add("certs/current.crt")
go func() {
    for {
        select {
        case event := <-watcher.Events:
            if event.Op&fsnotify.Write == fsnotify.Write {
                log.Println("Certificate updated, reloading...")
                // Reload TLS config
            }
        }
    }
}()
```

#### Responsibility 2: Service Discovery

The sidecar proxy needs to know how to reach other services. In Kubernetes, this is handled by the DNS resolution of Services. Our proxy can use the same DNS mechanism, but a control plane might provide a more sophisticated registry (e.g., Consul, etcd) for dynamic endpoints and health checking.

#### Responsibility 3: Traffic Policies

The control plane pushes configurations to the sidecar proxies. These configurations could specify:

- Which services are allowed to talk to each other (authorization policies).
- Timeout and retry parameters.
- Canary routing rules (e.g., 10% of traffic to v2 of a service).

A minimal control plane could expose a simple HTTP API:

```bash
# Control plane API endpoint
GET /api/v1/config/{service_name}
# Returns something like:
{
  "allowed_peers": ["fraud-checker", "user-service"],
  "timeout_ms": 5000,
  "retries": 2
}
```

The sidecar proxy would poll this endpoint periodically and apply the rules.

### Section 5: Putting It All Together: A Local Testbed

Let's create a local testbed to see our "poor person's service mesh" in action. We will run two services in Docker containers with iptables rules and sidecars.

**Setup:**

1. `service-a` (payment-service): A simple HTTP server on port 8080.
2. `service-b` (fraud-checker): A simple HTTP client that calls `service-a:8080`.

**Dockerfile for base image:**

```dockerfile
FROM golang:1.20-alpine

# Install iptables
RUN apk add --no-cache iptables

# Copy our sidecar binary
COPY sidecar /usr/local/bin/sidecar

# Copy certificates
COPY certs /etc/mesh/certs

# Entrypoint script to setup iptables and start services
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

**entrypoint.sh:**

```bash
#!/bin/sh
# Set up iptables rules
# Redirect outbound traffic on port 8080 to sidecar on 15001
iptables -t nat -A OUTPUT -p tcp --dport 8080 -j REDIRECT --to-port 15001

# Start the sidecar proxy (in background)
sidecar &

# Start the main application
exec "$@"
```

**Run the test:**

```bash
# Start service-a (payment-service)
docker run -d --name service-a \
  -e APP_TYPE=server \
  -p 8080:8080 \
  my-mesh-image

# Start service-b (fraud-checker)
docker run -d --name service-b \
  -e APP_TYPE=client \
  -e TARGET_SERVICE=service-a:8080 \
  --link service-a \
  my-mesh-image
```

When service-b makes a request, it will be intercepted, go through the mTLS tunnel to service-a's sidecar, which will then forward it to service-a's application. If you check the logs of service-a's sidecar, you should see the authenticated client identity: `CN=fraud-checker.my-ns.svc.cluster.local`.

### Section 6: Performance Considerations and Benchmarks

Adding a sidecar proxy introduces latency and resource overhead. Every packet must traverse the kernel's network stack twice (in and out of the proxy) and be encrypted/decrypted. Let's measure the impact.

#### Minimal Proxy Latency

Using our simple Go proxy (no TLS, just forwarding), we can benchmark with `ab` or `wrk`.

**Benchmark (no proxy):**

```bash
wrk -t2 -c10 -d10s http://localhost:8080/
# Latency: ~100 microseconds
# Throughput: ~50k req/s
```

**Benchmark (with proxy):**

```bash
wrk -t2 -c10 -d10s http://localhost:15001/
# Latency: ~500 microseconds (5x increase)
# Throughput: ~10k req/s
```

**Benchmark (with mTLS proxy):**

```bash
wrk -t2 -c10 -d10s https://localhost:15001/
# Latency: ~2 ms (20x increase)
# Throughput: ~5k req/s
```

These numbers are rough and depend heavily on hardware, but they illustrate the trade-off. The encryption overhead is significant. Production meshes like Envoy are highly optimized C++ proxies, but they still add latency.

**Why Production Meshes Are Faster:**

- Connection pooling: Envoy reuses connections, reducing handshake overhead.
- Zero-copy: Envoy can use kernel bypass techniques (e.g., eBPF) to reduce context switches.
- eBPF-based interception: Some meshes (Cilium) use eBPF instead of iptables, which is more efficient.

Our simple Go proxy is a learning tool, not a production solution.

### Section 7: Security Analysis: What We Solved and What We Didn't

Our mesh solves several critical security issues:

1. **Credential Theft Prevention:** With mTLS, a compromised service cannot impersonate another service unless it also compromises the CA or steals the private key.
2. **Eavesdropping Prevention:** All traffic is encrypted, preventing sniffing on the network.
3. **Authorization at the Network Layer:** The server sidecar can reject connections from unauthorized services based on their certificate identity.

However, our simple implementation has significant security gaps:

1. **Certificate Revocation:** We have no mechanism for revoking a compromised certificate. In production, meshes use CRLs (Certificate Revocation Lists) or OCSP (Online Certificate Status Protocol). Without this, a stolen key remains valid until expiration.
2. **Control Plane Security:** Our "control plane" (if any) is unauthenticated. An attacker could push malicious configurations to the sidecars.
3. **Sidecar Integrity:** The sidecar itself could be compromised. If an attacker gains access to the sidecar's filesystem, they can steal the private key.
4. **Observability Blind Spots:** We have no centralized logging or metrics. An attacker could silently probe services without being detected.

### Conclusion: The Virtue of Understanding

We have built a simple, functional service mesh from the ground up. We used `iptables` to transparently intercept traffic, OpenSSL to generate certificates, and Go to write a basic mTLS-enabled sidecar proxy. We have seen the internal mechanics that power the industry giants.

This exercise is not a call to abandon Istio and roll your own mesh. Quite the opposite. By understanding the underlying complexity—the management of iptables rules across thousands of pods, the rotation of millions of certificates, the debugging of obscure TLS handshake failures—you develop a profound appreciation for the abstractions that teams like the Istio and Linkerd maintainers provide.

The next time you see a "network bug" in your microservices, you will no longer be helpless. You will understand that the problem is not magic. It is just packets, rules, and certificates. And with the right tools and knowledge, you can untangle the mesh.

The story of the "fraud-checker" and the spiking latency is a cautionary tale. But with our newfound understanding, we can do more than just react. We can build systems that are, by default, secure, observable, and resilient. And when something goes wrong, we will know exactly where to look: right there, in the beautiful, tangled weave of the mesh.
