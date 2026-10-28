# Security Policy & Zero-Trust Verification Scope (`LFS-Tycoon`)

## 1. Supported Versions

Security updates, static allow-list gates, and sanitization checks are actively maintained on the default `main` branch:

| Branch / Version | Supported |
| :--- | :--- |
| `main` (HEAD) | Yes |
| Historical / Archived Branches | No (Read-only provenance) |

---

## 2. Zero-Trust Security Invariants (`ZT-1` – `ZT-10`)

This repository enforces strict security and privacy guardrails across all source files and automation scripts:

1. **Zero Hardcoded Secrets (`ZT-1`)**: No API keys, GitHub tokens (`ghp_*`, `github_pat_*`), OAuth secrets, private keys, or `.env` files are permitted in the repository.
2. **Zero PII & Portable Paths (`ZT-2`)**: All scripts and configurations use portable environment resolution (`$HOME`, `Path.home()`, relative repository paths) and prohibit personal identifiable information, private LAN/Tailscale IPs, or internal hostnames.
3. **Fail-Closed Static & Runtime Gates (`ZT-4`)**: All changes must pass deterministic verification before integration:
   ```bash
   python3 tools/check_capsules.py --strict && python3 -m unittest discover -s tests
   ```
4. **Redacted & Local-Only Diagnostics (`ZT-6`)**: Error outputs and diagnostic reports never transmit external telemetry or expose secret environment variables.

---

## 3. Reporting a Vulnerability

If you discover a security vulnerability, credential leak, or sandbox escape in this repository:

1. **Do NOT open a public GitHub issue** containing exploitable details or sensitive data.
2. Report the finding privately via **GitHub Security Advisories** at:
   `https://github.com/SyrisBruhh42/LFS-Tycoon/security/advisories/new`
3. Include a clear description of the issue, affected file path(s), and minimal reproduction steps.
