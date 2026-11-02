# Privacy Policy & Zero-Trust Data Governance (`LFS-Tycoon`)

**Effective Date**: November 1, 2026  
**Suite Release**: `LFS Oasis v2.0.0-cp12-argon4-apex`  
**Capsule / Project ID**: `lfs-tycoon` (`PF-07`)  
**Steward**: Lewis Family Systems (`SyrisBruhh42`)

---

## 1. Local-First Data Storage by Default

`LFS-Tycoon` is engineered around **Local-First Digital Sovereignty**:
- **Primary Persistence**: All application state, save slots, settings, and user creations are stored locally on your device using **Local Godot `user://` Save Lab (`aegisEnvelopeV1` AES-256-GCM) & SQLite WAL**.
- **100% Offline Capable**: The application functions offline without requiring cloud sign-in, external telemetry, or continuous internet connectivity.
- **Zero Third-Party Ad Trackers**: This repository contains zero advertising SDKs, behavioral tracking pixels, or third-party data broker integrations.

---

## 2. Opt-In Dual Cloud Storage (`LFS Server rclone` vs. `Personal Google Drive`)

Cloud synchronization is strictly **opt-in** and controlled by the user across two isolated lanes:

1. **Sovereign LFS Server Vault (`rclone` / `aegisEnvelopeV1` Lane)**:
   - When docked to a household LFS Oasis Server (`2-lfs-server`) or Linux Companion Hub (`3-lfs-aegis-linux`), save envelopes are encrypted client-side using **`aegisEnvelopeV1` (`AES-256-GCM` with `PBKDF2-HMAC-SHA256` / Argon2id key derivation)** prior to `rclone` or loopback vault synchronization.
2. **Personal Google Cloud / Workspace Lane (User-Owned Account)**:
   - When the user explicitly initiates Google OAuth sign-in (e.g., for personal Google Drive backups, Google Tasks/Keep bridges, or personal Firestore rooms), credentials are injected at runtime via `/api/lfs/vault/client-config` or local environment variables (`VITE_FIREBASE_API_KEY`) and scoped exclusively to the user's own account.

---

## 3. `ZT-6` Automated PII, Path & Secret Scrubbing

Before any diagnostic log, crash report, copilot prompt, or federated souvenir leaves the local runtime, the **`ZT-6` Zero-Trust Scrubber** deterministically redacts:
- **API Keys & OAuth Tokens**: Google Cloud keys (`AIzaSy*`), OAuth client secrets (`GOCSPX-*`), access/refresh tokens (`ya29.*`, `1//*`), OpenAI/Anthropic/GitHub tokens (`sk-*`, `ghp_*`, `gho_*`), and `Bearer` headers.
- **Cryptographic Material**: PEM/OpenSSH private keys and raw hex secrets.
- **Filesystem & Network PII**: Local OS usernames (`/home/<user>/` -> `$HOME/`), non-loopback RFC1918/Tailscale IPv4/IPv6 addresses, and raw SQL queries.

---

## 4. User Data Purge & Sovereignty Controls

Users retain complete ownership of their data at all times:
- Local SQLite WAL databases, IndexedDB stores, and `aegisEnvelopeV1` save files can be exported, inspected, or deleted directly from the local filesystem or browser storage settings.
- Opt-in cloud records include built-in purge routines to delete user-authored records on demand.
