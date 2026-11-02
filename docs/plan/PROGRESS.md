# Progress

Plan: [PLAN.md](PLAN.md) · Decisions: [DECISIONS.md](DECISIONS.md) · Open questions: [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md)

**Status key:** ☐ not started · ◐ in progress · ☑ done · ⛔ blocked

| Phase | Status | Delivers | Checked by |
|---|---|---|---|
| P0 | ☑ | Repo, package, proto, zlib compile, lints, plan docs | Builds and tests, including the watch target |
| P1 | ☐ | Diagnostics screen, bare locked recording on phone and watch | A0, rough A1 and A2. **Stop and report**: this decides the adapter design |
| P2 | ☐ | Storage and `sensing-decode` | Android test vectors; `compat.sh` both ways |
| P3 | ☐ | Engine, config, activity sessions, outbox | Fake-adapter soak; killing a writer process and recovering |
| P4 | ☐ | Phone motion adapters, keep-alive, minimal app | A1, A3, A4, A11 (phone) |
| P5 | ☐ | Watch app, workout, link, transfer, clock pairing, recovery | A2, A8, A9, A10 |
| P6 | ☐ | Location, activity, device state, sound, Bluetooth | A11 (rest), A12, A13 |
| P7 | ☐ | Full example app, labels, export | A7, A14, A15 |
| P8 | ☐ | Soak, tuning, docs; KB repo table updated and that page republished | A5, A6 |

## P0

- ☑ Package with its targets, swift-protobuf 1.39.0, minimum iOS 17 / watchOS 10 / macOS 14
- ☑ `sensorlog.v1` copied from sensing-sdk @183d765 and generated; `scripts/check.sh` compares it against the pin
- ☑ `import zlib` compiles and links for watchOS and iOS, with real gzip members (no hand-built wrapper), 2026-11-02
- ☑ Known answers pass: identifier hash `b57a3b2f7dad4b8a`, CRC-32 `0xCBF43926`
- ☑ `scripts/check.sh` with its lints
