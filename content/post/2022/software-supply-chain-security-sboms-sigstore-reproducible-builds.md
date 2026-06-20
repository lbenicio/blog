---
title: "Software Supply Chain Security: SBOMs, Sigstore, Reproducible Builds, and Attestation"
description: "An in-depth guide to securing the software supply chain: SBOMs, provenance, Sigstore, SLSA, reproducible builds, code signing, and operational best practices."
date: "2022-04-19"
author: "Leonardo Benicio"
tags: ["supply-chain", "sbom", "sigstore", "reproducible-builds", "slsa", "security"]
categories: ["security", "devops"]
draft: false
cover: "/static/assets/images/blog/software-supply-chain-security-sboms-sigstore-reproducible-builds.png"
coverAlt: "Illustration of a supply chain diagram with source control, CI/CD, artifacts, SBOMs, and attestation"
---

The software supply chain is the set of processes, tools, and artifacts that transform source code into software that runs in production. Protecting that supply chain is critical: compromises at any step — compromised dependencies, corrupted CI/CD pipelines, or forged releases — can lead to large-scale incidents that affect thousands of downstream systems.

This post explains the modern toolbox for defending the software supply chain: Software Bill of Materials (SBOM) formats and generation, provenance and attestation concepts, Sigstore for transparent signature & provenance, reproducible builds, SLSA (Supply chain Levels for Software Artifacts), secure signing and key management, package ecosystem-specific hazards (npm, PyPI, crates.io), and operational practices for CI/CD and incident response.

## 1. Why supply chain security matters

Software systems are composed of many moving parts: open-source packages, container images, build tools, third-party binaries, plugins, and deployment scripts. A single malicious or vulnerable dependency used in many projects can scale into widespread compromise.

Historic incidents underscore the problem:

- The SolarWinds compromise (2020) demonstrated how an attacker levering CI and release signing trust can distribute malicious updates widely.
- The use of typosquatted packages in package ecosystems (npm/PyPI) exposes projects to supply-side injection by malicious actors.
- Compromised CI credentials enabling an attacker to push signed binaries or new versions with backdoors.

Supply chain security aims to reduce the blast radius of such attacks by increasing visibility (SBOMs), integrity guarantees (signatures and attestations), reproducibility (reproducible builds), and best-practice controls (CI isolation, least privilege, and attestation policy enforcement).

## 2. SBOMs: what they are and why they help

An SBOM (Software Bill of Materials) is a formal record describing the components and dependencies that make up a software artifact. SBOMs provide:

- Transparency: who depends on what, including transitive dependencies.
- Auditability: help teams discover components with known vulnerabilities.
- Compliance: evidence for licensing and provenance requirements.

### 2.1 Common SBOM formats

- SPDX: a widely adopted format with a detailed taxonomy for licenses, package relationships, and file-level evidence. SPDX supports machine-readable RDF/JSON and text summaries.
- CycloneDX: designed specifically for software BOMs, with compact JSON/XML payloads and focus on security use-cases and vulnerability tooling.

Choosing a format depends on toolchain compatibility and ecosystem expectations. CycloneDX has strong adoption in security tooling, while SPDX is widely used for licensing and compliance workflows.

### 2.2 Generating SBOMs

SBOMs can be generated at multiple points:

- At build time: capture exact dependency graph used by the build system (e.g., Maven, npm, Cargo). Tools like `cyclonedx` or `syft` can analyze lockfiles and produced artifacts.
- From artifacts: inspect container images or binary packages to extract metadata and embedded package information.

Best practice: generate SBOMs as part of CI/CD, attach them to the artifact in the registry, and sign the SBOM alongside the artifact to bind the two.

## 3. Provenance and attestations

SBOMs list components, but who produced an artifact and how it was built is equally important. Provenance records describe the origin of an artifact and can include:

- The commit SHA of the source repository used to build the artifact.
- The exact build command and environment (OS, toolchain versions).
- Links to the SBOM and test results.

Attestations are signed statements (structured metadata) asserting properties about artifacts, e.g., "artifact X was built by CI job Y at time T".

### 3.1 In-toto and provenance formats

- In-toto defines a framework for securing the integrity of the software supply chain by modeling steps (called "links") and cryptographic signing of step metadata. Links capture who ran what, on which materials, and produce output materials.
- The newer provenance formats, such as the GitHub Actions `provenance` and the in-progress standardized `provenance` fields in OCI image manifests, aim to provide interoperable provenance metadata.

## 4. Sigstore and transparent signing

Sigstore is an open-source project that provides transparent, verifiable signing for software artifacts, emphasizing developer convenience and strong cryptographic assurance.

Key components:

- Fulcio: a short-lived certificate authority that issues ephemeral certificates to signers after authenticating them through an OpenID Connect (OIDC) flow.
- Rekor: a transparency log (append-only) that records signatures and certificates, enabling public audit.
- Cosign: a CLI tool to sign container images and other artifacts using keys or OIDC-based ephemeral certs.

Sigstore's model reduces long-lived key management burden and provides public transparency: signatures are logged, making it possible to detect suspicious signatures or key misuse.

### 4.1 Example: signing an image with cosign

```sh
cosign sign --key cosign.key example.com/org/image:tag
# or use OIDC (no key needed)
cosign sign --oidc example.com/org/image:tag
```

Cosign can also generate and sign a provenance attestation (in-tree or using `notation`), and Rekor stores the signature for later audit.

## 5. Reproducible builds: reducing trust in builders

A reproducible build ensures that given the same source and dependencies, the build process produces bit-for-bit identical artifacts. Reproducible builds provide strong guarantees:

- They allow independent parties to rebuild and verify that an artifact matches what was released, detecting injected binaries.
- They reduce reliance on trusting a single build environment.

### 5.1 Challenges to reproducibility

- Non-deterministic inputs: timestamps, build paths, locale differences, and randomized data can cause variations.
- Dependency immutability: external mirrors or registries changing artifacts can alter build outputs.

Mitigations:

- Fix timestamps or use deterministic timestamps (SOURCE_DATE_EPOCH).
- Normalize build environments with containers or Nix-style declarative environments.
- Vendor or lock dependencies with cryptographic checksums (lockfiles, shrinkwrap).

## 6. SLSA: a provenance & policy framework

SLSA (Supply chain Levels for Software Artifacts) is a framework defining increasing levels of assurance (SLSA 1 through 4) for build provenance and artifact integrity. Each level specifies requirements such as:

- SLSA 1: basic provenance (e.g., build record exists).
- SLSA 2: tamper-evident builds (signed provenance), CI-based builds.
- SLSA 3: non-falsifiable provenance (builds in trusted, isolated environments) and stronger controls.
- SLSA 4: fully verifiable builds with reproducible artifacts and hardened supply chain controls.

Adopting SLSA helps organizations plan incremental improvements and set measurable goals for artifact trustworthiness.

## 7. Package ecosystem hazards and mitigations

Different ecosystems have different risks:

- npm: high churn, easy publishing, and historical issues with malicious packages and typosquatting.
- PyPI: similar to npm, with some cases of dependency confusion and malicious wheels.
- Crates.io: centralization and build artifacts risks, though Rust's crate ecosystem often compiles from source.

Mitigations:

- Use lockfiles with strict checksums (`package-lock.json`, `Pipfile.lock`, `poetry.lock`, `Cargo.lock`).
- Use dependency scanning and SBOM integration to detect known vulnerabilities.
- Consider private registries for production-critical dependencies and vetting of packages.

## 8. CI/CD hardening and build environment isolation

CI systems are prime targets: compromised CI credentials or runners allow attackers to alter artifacts. Key practices:

- Least privilege: grant CI jobs only the permissions they require, and use short-lived tokens.
- Isolated runners: prefer ephemeral, single-use runners for untrusted jobs and use separate runners for critical signing steps.
- Review gates: require mandatory code review approvals for changes to build scripts, signing configs, or deployment manifests.

### 8.1 Secrets and key management

- Use a secrets manager (vault, cloud KMS) with auditable access policies.
- Avoid storing long-lived private keys on runners; use HSM/KMS-based signing where possible or rely on Sigstore's ephemeral certs.

## 9. Attestation policies and enforcement

Attestations are only useful when enforced: policy engines should verify provenance and SBOMs before permitting artifact promotion.

- Implement admission controllers (e.g., Kubernetes OPA/Gatekeeper) that check image provenance and required signatures before allowing deployments.
- Use CI gates to reject builds missing SBOMs or required attestations (e.g., test coverage attestation, vulnerability scan attestation).

## 10. Secure updates and rollback strategies

Software updates are an attack vector; ensure update mechanisms are authenticated and have safe rollback strategies:

- Signed updates and validation: clients must validate signatures and provenance before applying updates.
- Use monotonic versioning and metadata checks to prevent rollbacks to compromised older releases unless explicitly authorized.
- For critical infrastructure, staged rollouts and progressive canarying reduce blast radius.

## 11. Case study: SolarWinds and what changed

The SolarWinds incident demonstrated a sophisticated compromise of the build and signing pipeline, leading to widely distributed malicious updates. Key takeaways:

- The need for strong CI isolation and verification of build outputs.
- Value of external audits and cross-validation where possible.
- Importance of reproducible builds and independent reconstruction of releases to detect tampering.

## 12. Operational runbook: compromise detection and response

Detection signals:

- Unexpected provenance: release artifacts signed by unknown keys or produced by unknown build jobs.
- Anomalous package metadata changes or newly introduced transitive dependencies.
- Alerts from CT/SBOM monitoring or external vulnerability feeds.

Immediate response steps:

1. Stop distribution/publishing of the artifact and isolate registries.
2. Revoke any compromised signing credentials and rotate keys.
3. Snapshot affected artifacts and build environments for forensic analysis.
4. Rebuild artifacts from source in isolated environment and compare checksums.
5. Notify downstream consumers and coordinate a fix/rollback.

## 13. Tooling landscape: what to adopt today

- SBOM generation: Syft, CycloneDX tooling, SPDX generators.
- Signing and transparency: Sigstore (Fulcio, Rekor, Cosign), Notation integration.
- Provenance & attestation: in-toto, SLSA checkers, Grafeas/Artifact Registry with provenance support.
- Vulnerability scanning and policy enforcement: Trivy, Grype, OPA/Gatekeeper.

## 14. Developer experience: making supply chain security usable

Security measures must be usable to get adoption:

- Automate SBOM and attestation generation in CI with minimal developer intervention.
- Provide clear, actionable failure messages when policies reject a build.
- Offer developer-friendly signing paths (Sigstore OIDC flow) instead of complex key management by individuals.

## 15. Reproducibility in container images

Container images should be built from pinned base images and producing deterministic manifests where possible. Approaches:

- Use content-addressable image digests, not tags, in production manifests.
- Record and sign the exact manifest and associated SBOM/provenance.
- Rebuild images in isolated environments to verify digest equality.

## 16. Attesting source control and CI dependency chains

- Record commit SHAs and the CI job invocation parameters as part of provenance.
- Record builder environment versions and toolchain hashes (compiler versions, package manager versions).

## 17. Supply chain for third-party binaries and firmware

Third-party binary dependencies and firmware add complexity:

- Demand SBOMs and checksums from vendors; require signed releases and provenance.
- For firmware, preserve secure boot chains and require signed firmware updates with verifiable attestations.

## 18. Governance and compliance: policies and audits

Establish policies that define acceptable risk and artifact assurance levels. Policies should include:

- Required SBOM quality level and fields.
- Required attestations for production artifacts (e.g., test results, static analysis, vulnerability scan status).
- Audit schedules and third-party audits for critical components.

## 19. Measuring supply chain security maturity

Track metrics:

- Percentage of production artifacts with SBOMs attached.
- Percent of builds with signed provenance and required attestations.
- Time to detect and remediate compromised dependencies.

These metrics help plan SLSA level improvements and allocate resources.

## 21. in-toto example and layout (practical snippet)

in-toto provides a way to record steps in a supply chain and sign their output links. Below is a minimal example of an in-toto `layout` that requires a build step and a test step, both producing link metadata that is later verified.

```json
{
  "_type": "layout",
  "keys": {
    "builder": { "keyid": "abcd1234", "keytype": "rsa", "keyval": { "public": "..." } }
  },
  "steps": [
    {
      "name": "build",
      "expected_materials": [],
      "expected_products": [["CREATE", "artifact.tar.gz"]],
      "pubkeys": ["builder"],
      "expected_command": [["/bin/sh", "build.sh"]]
    },
    {
      "name": "test",
      "expected_materials": [["MATCH", "artifact.tar.gz", "FROM", "build"]],
      "expected_products": [["CREATE", "artifact-tested.tar.gz"]],
      "pubkeys": ["builder"],
      "expected_command": [["/bin/sh", "test.sh"]]
    }
  ],
  "inspect": []
}
```

A verification process runs `in-toto verify` with the layout and collected links (signed metadata from each step). This ensures the build followed the recorded steps and that artifacts are traceable.

## 22. CI signing workflow example (GitHub Actions)

Below is a concise GitHub Actions job that builds, generates an SBOM (using Syft), signs the image with Cosign using OIDC, and uploads an attestation to Rekor. This pattern avoids storing long-lived private keys on runners.

```yaml
name: build-and-sign
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write # required for OIDC
    steps:
      - uses: actions/checkout@v4
      - name: Build image
        run: |
          docker build -t ghcr.io/${{ github.repository }}:${{ github.sha }} .
      - name: Generate SBOM
        run: |
          syft -o cyclonedx-json --file=sbom.json ghcr.io/${{ github.repository }}:${{ github.sha }}
      - name: Sign image with Cosign (OIDC)
        run: |
          cosign sign --oidc ghcr.io/${{ github.repository }}:${{ github.sha }}
      - name: Upload provenance
        run: |
          cosign attest --predicate sbom.json --type cyclonedx ghcr.io/${{ github.repository }}:${{ github.sha }}
```

This job uses the OIDC flow and leaves no long-lived signing keys on the runner.

## 23. Nix, Guix and reproducible builds: practical strategies

Declarative build systems such as Nix and Guix give strong reproducibility guarantees by pinning exact package versions and build inputs in a reproducible graph. Practical tips:

- Use fixed-output derivations for binary outputs to ensure inputs produce expected digests.
- Employ `SOURCE_DATE_EPOCH` and other deterministic environment variables to remove time variance.
- Pin external resources and mirror artifacts in trusted registries.

For traditional build systems, containerizing the builder or using ephemeral, versioned builder VMs reduces environmental drift.

## 24. TUF and Notary for secure update frameworks

The Update Framework (TUF) provides a specification and metadata format for secure update distribution with delegations, threshold signing and key rotation. Notary v2 integrates TUF-like protections for container images and supports multiple trust roots.

Key benefits of TUF:

- Compromise resilience via role separation (root, snapshot, timestamp, targets)
- Rolling key rotation and delegated responsibilities
- Fine-grained control over which targets (artifacts) are signed by which keys

## 25. Notable incidents and lessons learned

- Event-Stream npm compromise (2018): an attacker took over an unmaintained package and added malicious code to a patched version. Lesson: maintainers and consumers should track package stewardship and use verification and review for critical dependencies.

- PyPI typosquatting / dependency confusion: publishing similar-sounding packages or registering names to trick users into installing malicious code. Lesson: Use scoped packages when possible and vet new transitive dependencies.

- SolarWinds: demonstrated the danger of signing compromised artifacts and the need for provenance and reproducible builds.

## 26. Attack trees and mitigations

Common supply-chain attack vectors:

- Compromised developer accounts (social engineering or credential theft).
- Malicious code in upstream dependencies.
- CI pipeline compromise (runner compromise or leaked secrets).
- Registry compromise (publishing malicious packages or replacing artifacts).

Mitigations map to each vector: MFA and phishing-resistant auth for developers, code review and dependency scanning, isolated CI runners and short-lived credentials, registry immutability and signed artifacts.

## 27. Incident response playbook (detailed)

1. Triage: identify affected artifacts and scope (via SBOMs and provenance).
2. Quarantine: disable distribution channels and deny new releases until verification.
3. Revoke & rotate: revoke signing keys and rotate credentials used by CI.
4. Rebuild & verify: re-run builds in an isolated environment and compare checksums to suspect artifacts.
5. Remediate: issue signed patches and coordinate with downstream users, including posting advisories and recommended rollback/patch actions.
6. Post-incident: run a retrospective, close security gaps (e.g., fix CI isolation, enable SLSA improvements), and update monitoring.

## 28. Developer & operator checklist (actionable)

- Add SBOM generation to CI and attach SBOMs to artifacts.
- Require signed provenance for production artifacts and verify attestations at promotion time.
- Use OIDC-based signing or HSM-backed keys for signing steps.
- Enforce dependency lockfiles and use vulnerability scanners with automated alerts.
- Harden CI: ephemeral runners, least privilege, and auditable logs.
- Pilot reproducible builds: target a small subset of critical artifacts first.

## 29. FAQ (short)

Q: Are SBOMs enough to prevent supply chain attacks?

A: No — SBOMs increase visibility but must be combined with attestations, signing, and runtime controls to be effective.

Q: Can we fully automate remediation for vulnerable dependencies?

A: Automation helps (e.g., PRs to update dependencies), but human review for high-impact changes is still essential.

## 30. Practical verification & CLI recipes

Verify a cosign signature and that it's recorded in Rekor:

```sh
# Verify the signature and certificate chain
cosign verify --key cosign.pub ghcr.io/org/image:sha256:abc123

# Verify that Rekor has a record of the signature (using cosign's Rekor integration)
cosign verify --rekor-url https://rekor.example.com ghcr.io/org/image:sha256:abc123
```

Quick SBOM checks (CycloneDX JSON + jq):

```sh
# Count unique packages in the SBOM
jq '.components | length' sbom.json
# Check for a specific package and version
jq '.components[] | select(.name=="openssl" and .version=="1.1.1k")' sbom.json
```

Rebuild and verify pipeline snippet (simplified):

```sh
# Rebuild in isolated environment and compare digests
docker build -t rebuilt:local .
docker inspect --format='{{index .RepoDigests 0}}' rebuilt:local
# compare with published digest
```

## 31. Policy-as-code example (OPA/Gatekeeper)

A minimal Rego rule that rejects Kubernetes Pod specs that reference container images without a matching signed attestation (pseudocode):

```rego
package kubernetes.admission

deny[msg] {
  input.request.kind.kind == "Pod"
  image := input.request.object.spec.containers[_].image
  not image_has_provenance(image)
  msg = sprintf("image %s missing signed provenance", [image])
}

image_has_provenance(image) {
  # Implementation: query an attestation index (by tag/digest)
  # and validate Rekor / Cosign presence. This example omits network
  # calls for brevity.
  true
}
```

In practice, integrate this with an admission controller that can query your attestation store or Rekor mirror.

## 32. TUF metadata snippet (targets example)

TUF's `targets.json` lists signed metadata about artifacts. A simplified example:

```json
{
  "_type": "targets",
  "spec_version": "1.0",
  "targets": {
    "myapp-1.2.3.tar.gz": {
      "hashes": { "sha256": "..." },
      "length": 123456
    }
  }
}
```

TUF clients confirm the signed `timestamp.json` and `snapshot.json` to ensure they fetch up-to-date, signed targets and to prevent rollback attacks.

## 33. 90‑day rollout roadmap (practical)

Week 1–2: Inventory & quick wins

- Generate SBOMs for critical services and store them with artifacts.
- Add daily vulnerability scans and alerts for critical findings.

Weeks 3–6: Enforce signing and provenance

- Add Cosign signing to CI using OIDC for images; attach SBOMs and attestations.
- Start Rekor mirror or use public Rekor with monitoring alerts.

Weeks 7–10: Policies & enforcement

- Deploy admission controllers (OPA/Gatekeeper) in staging to block unsigned images.
- Pilot reproducible builds for one critical service and verify digests.

Weeks 11–12: Harden & audit

- Rotate keys and move signing to KMS/HSM if needed.
- Conduct a focused audit or red-team around the CI pipeline.

## 34. Additional case study detail: small org attack vector

A small org relying on community packages and a single CI runner was compromised when a maintainer's account was phished. The attacker published a patched release with a build script that exfiltrated secrets at runtime. Mitigations that would have reduced impact:

- Enforce code review for changes to build scripts.
- Use ephemeral runners and restrict network access to build-time artifacts.
- Require signed attestation for production artifacts and detect unexpected provenance origins.

## 35. Final checklist (governing sprint tasks)

- SBOMs in CI for all builds ✅
- Cosign signing (OIDC) and Rekor logging ✅
- Admission controller in staging verifying attestations ✅
- Rebuilds proving digest reproducibility (pilot) ✅
- Incident response playbook and monitoring alerts ✅

## 36. Closing and further reading

Defending the supply chain is an iterative, cross-functional effort involving developers, build engineers, security, and operations. Start with visibility (SBOMs) and signing (Sigstore), then add reproducibility and policy enforcement. Consider SLSA as a roadmap and measure progress with actionable metrics.

Further reading:

- SLSA: `https://slsa.dev/`
- Sigstore: `https://sigstore.dev/`
- in-toto: `https://in-toto.io/`
- CycloneDX/SPDX documentation
- Reproducible Builds project and Debian reproducibility efforts

## Appendix A: SBOM diff & verification example

A small script to diff two CycloneDX SBOMs by package name and version (using `jq`):

```sh
jq -r '.components[] | "\(.name)@\(.version)"' sbom-old.json | sort > old.txt
jq -r '.components[] | "\(.name)@\(.version)"' sbom-new.json | sort > new.txt
diff -u old.txt new.txt
```

This highlights package upgrades, additions, and removals between builds.

## Appendix B: Registry policies & lifecycle

- Enforce immutability for release tags and prefer digests in deployment manifests.
- Retain provenance and SBOM artifacts for a retention window aligned with compliance needs (e.g., 1 year minimal for many regulated environments).
- Audit registry write permissions and require signed artifacts for production namespaces.

## Appendix C: grype/trivy CI snippet

Example of running a quick vulnerability scan in CI and failing the job on high-severity findings:

```yaml
- name: Scan image for vulnerabilities
  run: |
    grype ghcr.io/${{ github.repository }}:${{ github.sha }} -o json > grype.json
    if jq '.matches[] | select(.vulnerability.severity=="CRITICAL")' grype.json | grep -q .; then
      echo "Critical vulnerabilities found"; exit 1
    fi
```

## Appendix D: Attestation lifecycle & retention

Retention policy recommendations:

- Keep signed attestations and SBOMs for at least 1 year; longer if regulatory obligations require it.
- Archive attestations in an immutable store (WORM) and mirror Rekor logs to internal read-only archives for forensic purposes.

## Appendix E: Tools comparison

| Category                  | Example tools                   | Notes                                                   |
| ------------------------- | ------------------------------- | ------------------------------------------------------- |
| SBOM generation           | Syft, CycloneDX CLI, SPDX tools | Choose format based on downstream tooling compatibility |
| Signing & transparency    | Cosign, Rekor, Fulcio           | OIDC-based flows reduce key management burden           |
| Provenance & attestations | in-toto, SLSA checkers, Grafeas | Use in CI to generate verifiable metadata               |
| Vulnerability scanners    | Grype, Trivy                    | Integrate into CI and policy gates                      |

---

## Appendix F: 90‑day rollout roadmap (detailed)

Week 1–2: Inventory & quick wins

- Generate SBOMs for critical services and store them with artifacts.
- Add daily vulnerability scans and alerts for critical findings.

Weeks 3–6: Enforce signing and provenance

- Add Cosign signing to CI using OIDC for images; attach SBOMs and attestations.
- Start Rekor mirror or use public Rekor with monitoring alerts.

Weeks 7–10: Policies & enforcement

- Deploy admission controllers (OPA/Gatekeeper) in staging to block unsigned images.
- Pilot reproducible builds for one critical service and verify digests.

Weeks 11–12: Harden & audit

- Rotate keys and move signing to KMS/HSM if needed.
- Conduct a focused audit or red-team around the CI pipeline.

---

## 37. Rekor and transparency log queries (practical)

Rekor exposes a searchable transparency log that you can query to find signatures and certificates related to an artifact. Using `rekor-cli` or the Rekor API you can search by artifact hash or by the entry details.

Example (rekor-cli):

```sh
# Search Rekor for entries by artifact hash
rekor-cli search --artifact-sha sha256:abcdef1234567890

# Fetch an entry by UUID
rekor-cli get --log-index 1234
```

This allows teams to write monitoring that alerts if a signature appears from an unexpected principal or if a new signature for a production image is logged unexpectedly.

## 38. Cosign attestations & predicate formats

Cosign supports attesting arbitrary JSON predicates (e.g., SBOMs, test reports) using the `cosign attest` command. Predicates can be standard types (e.g., SLSA predicate) or custom JSON blobs that your policy can validate.

```sh
# Attest with a custom predicate file
cosign attest --predicate predicate.json ghcr.io/org/image:sha256:abc123
```

A verifier checks the predicate contents, signature presence in Rekor, and that the predicate meets policy constraints (e.g., contains an approval field or passes a vulnerability gate).

## 39. in-toto link example

A link file is a signed JSON blob describing inputs and outputs of a step. Example (simplified):

```json
{
  "name": "build",
  "materials": ["git+https://github.com/org/repo@refs/heads/main"],
  "products": ["artifact.tar.gz"],
  "byproducts": { "exit-code": 0 }
}
```

These links are signed by the runner and can be aggregated and verified against a layout to confirm the end-to-end process.

## 40. Language-specific SBOM extraction notes

- Java (Maven/Gradle): use CycloneDX plugin or `mvn dependency:tree` with CycloneDX generator to capture jar coordinates and transitive deps.
- Go: `syft` can inspect Go module metadata and built binaries; prefer `go.sum` for checksums.
- .NET: use NuGet export tooling and CycloneDX plugins to capture package references.

Always prefer generator tools that integrate with the package manager to ensure accurate transitive dependency resolution.

## 41. Firmware & hardware supply chain considerations

Firmware and hardware add boot-time risks. Important practices:

- Require signed firmware images and validate signatures using secure boot mechanisms (UEFI Secure Boot, TPM-based attestation).
- Maintain firmware SBOMs and track vendor-supplied binary blobs and their provenance.
- Use measured boot and remote attestation to detect compromised boot chains in critical systems.

## 42. SLSA mapping to internal policy (example)

Map SLSA levels to concrete organizational controls:

- SLSA 2 target: CI-signed builds, signed provenance, and automated generation of SBOMs.
- SLSA 3 target: enforce builder isolation, tamper-evident logs for signing, and mandatory attestation verification in staging.
- SLSA 4 target: reproducible builds, HSM-backed signing, third-party attestation, and rigorous hardening of build infrastructure.

Consider a phased plan where each milestone corresponds to audit-able checks in your CI/CD pipeline.

## 43. Open-source maintainer checklist (practical)

- Enable MFA and phishing-resistant auth on maintainers' accounts.
- Use CI badges that show whether a release build had a signed attestation.
- Rotate and limit access to release signing keys; prefer delegated signing services.
- Provide a clear process for contributors to validate their changes and for security reporting.
- Use automated SBOM generation on PRs to ensure new transitive dependencies are visible early.
- Add `CODEOWNERS` or protected branches for changes to build scripts and release tooling.

## 44. Common pitfalls and how to avoid them

- Treating SBOMs as a checkbox: ensure they are accurate and used in automations.
- Relying solely on vulnerability scanners without context: triage vulnerabilities with runtime and exploitability data.
- Ignoring provenance: knowing where an artifact came from is as important as knowing what's in it.
- Over-reliance on a single signer or key: prefer KMS/HSM-backed signing or short-lived certs where possible.

## 45. Developer quickstart: Cosign + Syft in GitHub Actions (step-by-step)

1. Enable OIDC for your GitHub organization (Actions > Settings > OIDC).
2. Add a job to build, generate SBOM, and sign with Cosign:

```yaml
name: Quickstart: build, sbom, sign
on: [push]
jobs:
  quickstart:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4
      - name: Build image
        run: |
          docker build -t ghcr.io/${{ github.repository }}:${{ github.sha }} .
      - name: Generate SBOM (Syft)
        run: |
          syft -o cyclonedx-json ghcr.io/${{ github.repository }}:${{ github.sha }} > sbom.json
      - name: Sign image (cosign)
        run: |
          cosign sign --oidc ghcr.io/${{ github.repository }}:${{ github.sha }}
```

1. Verify in a separate job or stage that the attestation exists in Rekor and that the SBOM matches expectations.

## 46. Testing & CI checklist

- Ensure SBOM generation runs on PRs and is checked into logs for review.
- Add a nightly job that attempts to rebuild a checkpointed release to test reproducibility.
- Run grype/trivy on images and fail on CRITICAL-only policies in CI.
- Audit and log all signing events; alert on unexpected signers.

---

In closing: defend the software supply chain by combining visibility (SBOMs), attestations, and enforced policies; iterate from easy wins to stronger guarantees like reproducibility and SLSA maturity.

## 45. SolarWinds: deeper timeline and mitigations

Timeline highlights and additional mitigation analysis:

- Initial compromise: attacker inserted malicious code into the build system and backdoored the Orion product.
- Distribution: signed updates were released through the normal update channels, making them appear legitimate to downstream customers.
- Detection: monitoring and external reporting led to discovery; patching and revocation followed.

Additional mitigations to consider beyond the obvious:

- Build reproducibility checks for critical releases to enable independent verification that published binaries match source.
- Enforce multi-person review and splitting the signing process across roles (separation of duties) to reduce single-point compromise risk.
- Implementing strong runtime detection on endpoints (behavioral indicators) to detect anomalous behavior despite signed updates.

## 46. Cosign + KMS/HSM example (AWS KMS)

Using KMS simplifies key management and allows signatures to be produced without extracting private key material to runners:

```sh
# Configure cosign to use an AWS KMS key
export COSIGN_KMS_KEY=aws-kms://arn:aws:kms:us-east-1:123456789:key/abcd-efgh
cosign sign --kms $COSIGN_KMS_KEY ghcr.io/org/image:sha256:abc123
```

This stores signing material in KMS and allows centralized rotation and IAM-based access control.

## 47. OPA/rego sample for SBOM-based policy

A simple policy to reject images where the SBOM indicates a CRITICAL vulnerability (using a precomputed vulnerability list in the admission controller):

```rego
package kubernetes.admission

deny[msg] {
  input.request.kind.kind == "Pod"
  some i
  image := input.request.object.spec.containers[i].image
  vulnerabilities := get_vulns_for_image(image)
  vulnerabilities[_] == "CRITICAL"
  msg = sprintf("image %s has critical vulnerabilities", [image])
}
```

The `get_vulns_for_image` function would query a vulnerability index populated by CI scans or an external scanning service.

## 48. Incident notification template

Subject: [SECURITY] Supply Chain Incident: [artifact] - [short summary]

Body:

- Summary of the incident and affected artifacts
- Time window and scope of distribution
- Immediate recommendations (e.g., stop pulling image X, roll back to Y)
- Actions taken (revoked keys, isolated registry)
- Contact points and follow-up plan

## 49. Glossary (short)

- SBOM: Software Bill of Materials — a list of components and dependencies that make up an artifact.
- Attestation: a signed statement describing properties of an artifact (e.g., built-by, tests-passed).
- Rekor: Sigstore's transparency log for signatures and attestations.
- SLSA: Supply chain Levels for Software Artifacts — a maturity framework.

---

How to get started in one hour:

- Generate an SBOM for a single critical service (`syft` or CycloneDX plugin) and store it as an artifact in CI.
- Add a GitHub Actions step to sign images with `cosign --oidc` and verify the Rekor entry appears.
- Run a quick vulnerability scan (`grype`) and set an alert for any CRITICAL findings.

Call to action: pick one service and roll out the three steps above in a single sprint; measure results and iterate toward broader coverage.

In closing: defend the software supply chain by combining visibility (SBOMs), attestations, and enforced policies; iterate from easy wins to stronger guarantees like reproducibility and SLSA maturity. Measure and report progress monthly to maintain momentum. If you'd like, I can help audit one repository and implement the quickstart in a sprint.
