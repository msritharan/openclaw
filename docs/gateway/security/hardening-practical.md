---
summary: "Practical guide to hardening openclaw with focus on security-usability tradeoffs"
read_when:
  - You want to understand the real-world exploits and gaps in restrictive security settings
  - You need to balance security with usability for different agent types
title: "Hardening Practical Guide"
---

# Hardening Practical Guide

This guide complements the main [Security documentation](/gateway/security/) by focusing on the tradeoffs, exploits, and decision framework for balancing security with usability.

> For configuration reference and quick-start hardened baseline, see [Security](/gateway/security/).

## The Core Tension

Restrictive settings create a paradox:

- **Maximum security** = no network, no filesystem, no exec = useless agent
- **Maximum usability** = full access = catastrophic blast radius if compromised

The goal is **defense in depth** with **least privilege per context**, not blanket restriction.

## Potential Exploits & Gaps in "Maximum Restriction"

### 1. `network: "none"` — Breaks Legitimate Tool Use

**What it blocks:**

- Package downloads (`npm install`, `pip install`)
- External API calls (LLM providers, webhooks)
- DNS resolution

**What it doesn't block:**

- DNS tunneling to exfiltrate data (mitigated by sandboxing)
- Agents become effectively useless for most real work

**Real-world consequence:** Users disable it entirely, defeating the security benefit.

---

### 2. `workspaceAccess: "none"` — Total Filesystem Lockout

**What it blocks:**

- Reading conversation history
- Writing generated code/artifacts
- Accessing project files

**Reality:** This makes openclaw unusable for most agents. They need filesystem access to be productive.

---

### 3. `execApproval: { ask: "always" }` — Human-in-the-Loop Bottleneck

**What it blocks:**

- Automation pipelines hang waiting for approval
- Long-running tasks cannot run unattended

**Security gap:**

- The approval socket (`~/.openclaw/exec-approvals.sock`) must be protected
- If an attacker can write to it, they can approve their own malicious commands

---

### 4. Low Rate Limits — Self-DoS

| Setting                                       | Risk                                          |
| --------------------------------------------- | --------------------------------------------- |
| `maxAttempts: 3` with `exemptLoopback: false` | Legitimate users lock themselves out on typos |
| Short `lockoutMs`                             | Attacker can repeatedly trigger lockouts      |

---

### 5. `tls: autoGenerate` — Self-Signed Certs

**Usability cost:** Browsers show security warnings. Users click through warnings, normalizing bad security behavior.

**Production recommendation:** Use real certificates from Let's Encrypt or your CA.

---

### 6. Sandbox Memory `256m` — OOM Kills

| Operation                     | Memory Need |
| ----------------------------- | ----------- |
| `npm install` (small package) | 300-500MB   |
| Python scipy/tensorflow       | 500MB-2GB   |
| Running tests                 | 200-400MB   |

**Attack vector:** Craft inputs that force OOM → denial of service.

---

### 7. Browser `allowHostControl: false` — But Browser Is Still a Risk

Even with this setting, a compromised browser sandbox can:

- Capture screen content (if VNC enabled)
- Keylog when browser has input focus
- Download malicious files to bind mounts

---

## Decision Framework: Security vs Usability

### Think in Terms of Agent Types

| Agent Context                 | Risk Level | Appropriate Restrictions                                        |
| ----------------------------- | ---------- | --------------------------------------------------------------- |
| **Read-only research agent**  | Low        | `workspaceAccess: "ro"`, `network: "none"`                      |
| **Code writing agent**        | Medium     | `workspaceAccess: "rw"`, `network: "bridge"`, allow `npm`/`pip` |
| **Admin/operations agent**    | High       | Full exec, but require approval + audit logging                 |
| **Untrusted/sandboxed agent** | Critical   | Full isolation, no network, minimal tools                       |

### Key Decision Tree

```
1. Does the agent need internet access?
   NO  → network: "none"
   YES → Use ssrfPolicy to limit destinations

2. Does the agent need filesystem access?
   NO  → workspaceAccess: "none"
   YES → Start with "ro", escalate to "rw" only when needed

3. Does the agent run unattended (CI/automation)?
   YES → execApproval: "allowlist" with pre-approved commands
   NO  → execApproval: "deny" + "always" ask

4. Can the agent be compromised by user input?
   YES → Keep sandbox enabled (mode: "all")
   NO  → Consider sandbox: "off" for trusted internal agents

5. What happens if the agent is fully compromised?
   → Determines how restrictive outer layers should be
   → Isolate high-value targets; accept more risk for low-value tasks
```

### The Core Question

For each restriction, ask:

> **"What specific threat does this block, and what is the cost to legitimate use?"**

If you can't name the specific threat, the restriction may be theater. If the cost is too high, the restriction won't be followed in practice.

---

## Blast Radius Analysis

The sandbox being restrictive doesn't mean outer layers should be open. If the sandbox escapes:

| If sandbox escapes to... | Blast radius    | Mitigation                                           |
| ------------------------ | --------------- | ---------------------------------------------------- |
| Host filesystem          | Full read/write | Use `workspaceAccess: "ro"` or bind to specific dirs |
| Network                  | Full internet   | Use `network: "none"` or SSRF policies               |
| Exec                     | Any command     | Use exec approval + `capDrop: ["ALL"]`               |

---

## Tiered Security Model

### Tier 1: Maximum Security (Untrusted/Internet-Facing)

```yaml
sandbox:
  mode: "all"
  docker:
    network: "none"
    readOnlyRoot: true
    capDrop: ["ALL"]
    pidsLimit: 128
    memory: "256m"

gateway:
  bind: "loopback"
  auth:
    mode: "token"

execApproval:
  security: "deny"
  ask: "always"
  autoAllowSkills: false

ssrfPolicy:
  allowPrivateNetwork: false
  dangerouslyAllowPrivateNetwork: false
```

**Use case:** Agents handling untrusted input, public-facing bots.

---

### Tier 2: Balanced Security (General Development)

```yaml
sandbox:
  mode: "all"
  workspaceAccess: "rw"
  docker:
    network: "bridge"
    memory: "1g"
    pidsLimit: 512
    capDrop: ["ALL"]
    readOnlyRoot: true

gateway:
  bind: "loopback"
  tls:
    enabled: true

execApproval:
  security: "allowlist"
  ask: "on-miss"
  autoAllowSkills: false

ssrfPolicy:
  allowPrivateNetwork: false
  allowedHostnames: [] # Be explicit
```

**Use case:** General-purpose development agents.

---

### Tier 3: Minimal Security (Trusted Internal)

```yaml
sandbox:
  mode: "off"

gateway:
  bind: "loopback"
  auth:
    mode: "token"

tools:
  profile: "standard"
```

**Use case:** Fully trusted internal agents, CI pipelines.

---

## Common Pitfalls

### 1. Over-restricting → Workarounds → Less Security

If you block everything:

1. Users enable dangerous workarounds
2. Those workarounds bypass your security
3. You're worse off than with balanced settings

**Better approach:** Start restrictive, widen deliberately as needed.

### 2. Ignoring Blast Radius

A setting that looks "secure" might have a large blast radius if bypassed:

| Setting                  | Bypass consequence                       |
| ------------------------ | ---------------------------------------- |
| `network: "none"`        | Agent is useless → disabled entirely     |
| `execApproval: "always"` | Slows work → disabled or bypassed socket |
| `workspaceAccess: "ro"`  | Can't write → may use dangerous tools    |

### 3. Forgetting Layered Defense

Single-layer security fails. Combine:

- Sandbox isolation
- Exec approval
- Rate limiting
- Network policies (SSRF)
- TLS/auth on gateway

---

## Quick Reference: Security Knobs

| Concern               | Most Restrictive        | Balanced                    | Least Restrictive     |
| --------------------- | ----------------------- | --------------------------- | --------------------- |
| Sandbox mode          | `"all"`                 | `"all"`                     | `"off"`               |
| Network               | `"none"`                | `"bridge"` + SSRF           | `"bridge"`            |
| Filesystem            | `"none"`                | `"rw"` + workspace binding  | Full access           |
| Exec approval         | `"deny"` + `"always"`   | `"allowlist"` + `"on-miss"` | `"full"`              |
| Memory limit          | `256m`                  | `1g`                        | Unlimited             |
| PID limit             | 128                     | 512                         | Docker default        |
| Capabilities          | `["ALL"]`               | `["ALL"]`                   | Docker default        |
| Rate limit (attempts) | 3                       | 5-10                        | 10+                   |
| Auth                  | `"token"` + strong pass | `"token"`                   | `"none"` (local only) |

---

## Related Documentation

- [Security Overview](/gateway/security/) — Main security documentation
- [Sandboxing](/gateway/sandboxing/) — Sandbox configuration details
- [Exec Approvals](/cli/approvals/) — Command approval system
- [Gateway Auth](/gateway/authentication/) — Authentication options
- [SSRF Protection](/gateway/security/) — Network access control
