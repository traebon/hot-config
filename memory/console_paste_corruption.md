---
name: console-paste-corruption
description: "Hostkey's native KVM console mangles pasted text (digits become shift-symbols, letters drop) but plain typed text comes through clean"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 662a2e2b-edf7-4613-857f-27ff2bf97ace
---

When Mr. Byrne pastes terminal/log output through Hostkey's native browser KVM console into a Claude Code session running on the Gateway VPS console (tty1), the pasted text arrives systematically corrupted: digits become their shifted symbol (1→!, 2→@, 3→#, etc.), letters drop, spacing collapses. This happens even for entirely legitimate, expected content (e.g. `ssh -vvv` debug output, Termius connection logs) — it is a keystroke-injection/keyboard-layout bug in the console's paste feature, not a sign of tampering or a compromised session.

**Why:** Discovered 2026-07-03 during an SSH-lockout troubleshooting session — dozens of garbled messages in a row (some repeating identical stale content, e.g. the same "Starting a new connection..." Termius log replayed many times with an unchanging screenshot filename reference) initially looked like an automated/hijacked session. Checking real-time server-side logs (`auth.log`, `journalctl -u ssh`) showed no corresponding activity, which momentarily raised suspicion of spoofing. Mr. Byrne confirmed afterward: it was just the Hostkey console's paste function stuck/misbehaving. Plain typed sentences (not pasted) came through perfectly clean throughout the entire episode — that was the tell.

**How to apply:** If garbled/corrupted pasted text shows up again in a session running on this console, don't immediately escalate to a security concern — first ask Mr. Byrne to *type* a short plain sentence directly instead of pasting, and compare. If typed text comes through clean while pasted text is garbled, it's this same console bug, not compromise. Only escalate to identity/compromise concerns if even directly typed responses are anomalous or the server-side logs contradict what's being reported as happening live.
