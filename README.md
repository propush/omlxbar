# omlxbar

A macOS menubar app for [oMLX](https://omlx.ai). The dot colour tells you what
the server is doing; clicking it — or pressing <kbd>⌥⌘O</kbd> from anywhere —
drops down the same serving stats the web dashboard shows, for every model at
once instead of one at a time.

## The dot

| Dot | Meaning |
|---|---|
| hollow grey | oMLX is not responding |
| green | server up, no model in memory |
| yellow | a model is resident but idle |
| yellow, pulsing | a model is loading its weights |
| red | a request is prefilling or generating right now |

## The overlay

- **Cumulative tiles** — Total Prefill Tokens, Cached Tokens, Cache Efficiency,
  Completion Tokens, Requests, with a Session / All-Time toggle
- **Average Speed** — Prompt Processing (excl. cached) and Token Generation
- **Model Memory** — resident bytes against the enforcer ceiling, or against
  installed RAM when the memory guard is off
- **Models** — every discovered model, resident ones first, each with its own
  token counts, cache efficiency, speeds and request count. Click a row to
  expand its parameters (context window, engine, temperature, top_p, top_k,
  max tokens, TTL).

While a model is working, its row shows live prefill progress and generation
rate per request.

If oMLX is stopped, the overlay falls back to the all-time totals the server
persists in `~/.omlx/stats.json`, so the history is still there.

## Build

```sh
./scripts/bundle.sh              # build/omlxbar.app
./scripts/bundle.sh --install    # also copy to /Applications and launch
```

Requires Swift 6 and macOS 14+. The script ad-hoc signs the bundle, which
Launch at Login needs.

## Configuration

Host, port and API key are read from `~/.omlx/settings.json` — the same file the
server reads — so there is nothing to configure. If the server rejects the
request, the app exchanges the API key for a session cookie via
`/admin/api/login` and retries.

Environment overrides, for pointing at an oMLX instance elsewhere:

| Variable | Effect |
|---|---|
| `OMLXBAR_URL` | full target URL, e.g. `https://box.local:8443` |
| `OMLXBAR_HOST` | override the host |
| `OMLXBAR_PORT` | override the port |
| `OMLXBAR_API_KEY` | override the API key |

**Transport.** Every request carries the API key, so plain HTTP is accepted only
for loopback. A non-loopback host must be `https://` with a valid certificate;
`OMLXBAR_HOST=box.local` is upgraded to HTTPS automatically, and an explicit
`OMLXBAR_URL=http://box.local:8000` is refused outright rather than silently
retargeted somewhere safer. A refused target shows an orange hollow dot and the
reason in the overlay — the app never falls back to a different server.

**When something is wrong.** The dot has three states that mean "do not trust
what is below it": grey hollow (not responding), and orange hollow for either a
refused target or a response this version cannot read. An unparseable payload is
never reported as an idle server. Statistics recovered from `~/.omlx/stats.json`
are labelled with the file's age, and are only ever used for a loopback target —
that file describes this Mac, not a remote server.

The global hotkey is stored in `UserDefaults` under `hotKeyCode` /
`hotKeyModifiers` (Carbon key code and modifier mask). It defaults to ⌥⌘O and is
registered with `RegisterEventHotKey`, so it needs no Accessibility permission.

## Checking it works

```sh
swift test                                  # decoding, refresh ordering, transport rules

.build/debug/omlxbar --selftest             # one poll, prints what the UI would show
.build/debug/omlxbar --selftest --alltime   # same, All-Time scope
OMLXBAR_PORT=9 .build/debug/omlxbar --selftest   # exercise the offline path
OMLXBAR_URL=http://example.com:8000 .build/debug/omlxbar --selftest   # refused target
```

The self-test runs the same client, decoding and merge logic the overlay does,
so its numbers should match the dashboard digit for digit.

## Notes

The app only ever reads from oMLX. It sends no request that changes server
state — no loading, unloading, or clearing of stats.
