# AGENTS.md

Notes for future coding agents working in this repo. Read this before making
non-trivial changes — there are a few constraints here that aren't obvious from
the source alone.

## What this repo is

A FreeSWITCH-based voice front-end for [retromusicbox](https://github.com/alexkinch/retromusicbox).
The retromusicbox backend (`rmbd`, Go) recreates the 1990s "The Box" interactive
music video channel, where users dial a 3-digit code to queue a video.

`rmbd` exposes a service-agnostic IVR session REST API and ships **zero** SIP,
RTP or codec code on purpose. This repo is one possible front-end driving that
API — there could equally be Asterisk, Twilio, or Jambonz variants. Keep that
boundary in mind.

## Hard design rules

These are not negotiable without an explicit conversation with the user first.

1. **Single-purpose IVR.** This is not a general-purpose dialplan framework.
   Don't add menu trees, voicemail, conferencing features, or extra extensions
   "while we're here."
2. **No application state in the Lua handler.** The IVR session lives in
   `rmbd`. The handler is pure translation: DTMF in, REST calls out, prompts
   played in response. If you find yourself wanting to remember something
   across calls in Lua, that signal almost always means it belongs in `rmbd`.
3. **Don't reach across into the rmbd repo.** The REST contract
   (`POST /api/ivr/sessions`, `/digit`, `/submit`, `DELETE`, `GET`) is the
   contract. If the contract genuinely needs to change, raise it with the user
   so they can change `rmbd`. Do not patch around `rmbd` in this repo.
4. **Cleanup-safe on every exit path.** Every code path in
   `scripts/retromusicbox.lua` — success, fail, hangup, exception — must end
   up issuing a `DELETE /api/ivr/sessions/{id}` for any session it created.
   The `pcall` wrapper at the bottom and the explicit `delete_session` calls
   at every return are how this is currently enforced. Don't break that.
5. **The image must remain self-contained.** A user with only a SignalWire
   token should be able to `docker compose up` and have a working SIP endpoint
   on 5080. Don't add steps that require pulling extra config from external
   systems at runtime.

## rmbd REST contract — quirks worth knowing

A session moves through four explicit states:

```
  dialling  -> caller is entering digits
  validated -> backend confirmed the code resolves to a catalogue entry
               and is waiting for the caller to press 1 (confirm) or
               2 / * (cancel). On-screen overlay shows artist + title.
  success   -> caller confirmed, request is on the queue ("Thanx!")
  fail      -> unknown code or rejected by the queue ("Try again")
```

| method | path | notes |
| --- | --- | --- |
| `POST` | `/api/ivr/sessions` | Returns `{session_id, expires_in_seconds}`. **Returns 429 if `ivr.MaxConcurrent` (default 3) sessions are already active** — this means "all lines busy", not "retry later". |
| `POST` | `/api/ivr/sessions/{id}/digit` | Body `{"digit":"5"}`. **State-aware**: in `dialling` it accumulates / `#` submits / `*` clears; in `validated`, `1` confirms and `2`/`*` cancel. Auto-submits when the 3rd digit is entered while dialling. |
| `POST` | `/api/ivr/sessions/{id}/submit` | Finalise dialling early. Not used here — auto-submit on the 3rd digit is enough. |
| `POST` | `/api/ivr/sessions/{id}/confirm` | Commit a `validated` session to the queue. Transitions to `success`. The handler uses this rather than forwarding `1` through `/digit` because the intent is clearer. |
| `POST` | `/api/ivr/sessions/{id}/cancel` | Roll a `validated` session back to empty `dialling`. The handler uses this rather than forwarding `2` / `*` through `/digit` for the same reason. |
| `DELETE` | `/api/ivr/sessions/{id}` | Caller hung up / cleanup. Idempotent. |
| `GET` | `/api/ivr/sessions/{id}` | Inspect current state. Not used by the script today. |

`validated` and `success` responses include `code`, `artist`, `title` in the
body so the IVR has something to read back. `fail` responses include both
`reason` (free-form, for logs) and `reason_code` (stable, for branching).
Codes: `incomplete_code`, `unknown_code`, `rate_limited`, `queue_error`.
The handler branches on `reason_code` so a rate-limited caller gets the
dedicated `limit-reached` prompt instead of the generic error one.

**The confirm window.** A `validated` session lives for `ivr.confirm_ttl_seconds`
on the rmbd side (default 15s). The "press 1 to confirm" prompt plus caller
thinking time must fit inside that window, otherwise `/confirm`, `/cancel`,
and `/digit` will return 404. Our `RMB_CONFIRM_TIMEOUT_MS` defaults to 10s so
the caller times out on our side first, while the rmbd session is still alive.
**If you ever bump `RMB_CONFIRM_TIMEOUT_MS`, keep it strictly less than the
rmbd `confirm_ttl_seconds`.** The handler treats a 404 from the confirm/cancel
call as `expired` and bails out cleanly with the error prompt.

**Cancel reuses the session.** After `/cancel`, the session is back to empty
`dialling` — `Status: "dialling"`, `Digits: ""`. The handler loops back to
collect more digits *without* creating a new session. Doing otherwise would
count against `MaxConcurrent` (the cancelled session is still occupying a
slot in the dialling state) and may 429.

**A failed session is dead.** Once a session is in state `fail`, you cannot
send more digits to it. For a retry, `DELETE` it and create a fresh one with
`POST /api/ivr/sessions`. This is fine because `fail` sessions don't count
against `MaxConcurrent` — they linger only for the on-screen result display.
The current handler already does this for the invalid-code retry path.

**Invalid codes skip the confirm step.** They go straight to `fail` from the
3rd-digit POST. Don't try to confirm a `fail` — it'll just return the same
fail snapshot. The handler treats `fail` as a code-rejected retry path
distinct from the `validated -> error` path.

## Repo layout

```
.
├── Dockerfile               # FS 1.10 + mod_lua + mod_curl + Callie sounds
├── docker-entrypoint.sh
├── docker-compose.yml       # standalone (host-net) for local dev
├── docker-compose.example.yml  # example: paired with rmbd in one stack
├── conf/
│   └── dialplan/public.xml  # routes any inbound DID into the Lua handler
├── scripts/
│   ├── retromusicbox.lua    # the IVR
│   └── config.lua           # env-driven runtime config
├── sounds/                  # custom prompts (see sounds/README.md)
├── .github/workflows/ci.yml # luacheck + xmllint
├── README.md
└── AGENTS.md                # you are here
```

## Why system curl instead of luasocket / cjson

`scripts/retromusicbox.lua` shells out to system `curl` via `io.popen` and
parses JSON with Lua patterns. This looks ugly compared to `require("socket.http")`
+ `require("cjson")` (which is what e.g. `~/Projects/alexkinch/chatbot/chatbot.lua`
does). The reason is concrete:

- mod_lua on the SignalWire FreeSWITCH Debian package bundles its own Lua
  (typically 5.2).
- Apt packages like `lua-cjson` and `lua-socket` install modules built against
  the system default Lua (5.4 on bookworm).
- The version mismatch causes silent `require()` failures or worse at runtime,
  inside the container.

`rmbd`'s payloads are small and flat (a handful of string and number fields).
Shelling out to `curl` and pattern-extracting individual fields removes the
whole class of Lua/library-version mismatch failures and keeps the image
smaller. **Don't switch to lua-cjson without first verifying at runtime that
the apt package installs into mod_lua's specific Lua version path.** If you
need richer JSON later (escaped quotes, arrays, nested objects), add a tiny
pure-Lua JSON decoder file before reaching for cjson.

## Local development workflow

```bash
cp .env.example .env
$EDITOR .env       # set SIGNALWIRE_TOKEN
docker compose build
docker compose up
```

This brings FreeSWITCH up on the external SIP profile, UDP/TCP **5080**, with
host networking so the wide RTP port range Just Works on Linux. Local-Mac
testing via Docker Desktop / Colima / OrbStack is a known sharp edge — none
of them forward a host-network container's UDP listeners cleanly to a Mac
softphone. For now, smoke-test on a Linux host (or a Linux VM with bridged
networking) until that's revisited.

Test with a softphone (Linphone, Zoiper) pointed at `<host-ip>:5080`, no auth,
dial any number. Tail logs with:

```bash
docker compose logs -f freeswitch | grep retromusicbox
```

## Local CI checks

Before pushing, you can run the same checks CI runs:

```bash
luacheck scripts/ --globals freeswitch session argv --no-unused-args --no-max-line-length
find conf -name '*.xml' -print0 | xargs -0 -n1 xmllint --noout
```

If `luacheck` isn't installed, `luac -p scripts/retromusicbox.lua scripts/config.lua`
at least catches syntax errors.

## Things that are deliberately not here, and why

- **No TTS at all — every word is a bespoke recording.** The IVR plays only
  the WAVs in `sounds/`: dialogue prompts (welcome, enter-code,
  you-entered, press-to-confirm, etc.) and per-digit clips
  (`sounds/digits/0.wav` .. `9.wav`). The confirm step reads the caller's
  code back as `you-entered.wav` followed by three digit clips in sequence.
  The artist and title are **not** spoken — they only appear on the
  channel's on-screen overlay during the validated window. If you later
  want them spoken too, that's a TTS add-on (espeak-ng / pico2wave /
  mod_flite / cloud TTS) that touches the Dockerfile, `config.lua`, and
  `run_confirm` in the Lua. Confirm with the user before adding it.
  Critically, **don't reach for `mod_say_en` as a fallback** — it was
  removed from the Dockerfile package list on purpose; mixing the stock
  Callie voice with the bespoke recordings sounds jarring.
- **No SIP authentication.** The vanilla external SIP profile on 5080 accepts
  unauthenticated calls. That's fine for dev and for an inbound-only carrier
  trunk that's locked down by IP. For any deployment exposed to the open
  internet you'd want ACLs / digest auth in `conf/sip_profiles/`. Don't enable
  these speculatively.
- **No custom `vars.xml` / `sofia.conf.xml`.** We inherit FreeSWITCH's vanilla
  config and overlay only `dialplan/public.xml`. Keep the override surface
  small — every file you add is something a user has to understand if they
  want to customise the deployment.
- **No persistent volumes.** State lives in `rmbd`; FreeSWITCH here is
  stateless. If you find yourself wanting a volume, you're probably violating
  rule 2 above.

## Common change patterns

- **Tweak prompt copy** → swap a wav into a mounted dir and override the
  matching `RMB_PROMPT_*` env var. No code change needed.
- **Change retry behaviour** → adjust `RMB_MAX_RETRIES` or the timeout vars in
  `scripts/config.lua`. The handler reads them on every call (no rebuild).
- **New REST endpoint exposed by rmbd** → add a wrapper in the "rmbd API
  wrappers" section of `scripts/retromusicbox.lua` and call it from the flow.
  Keep it cleanup-safe.
- **Bump FreeSWITCH version** → change `DEBIAN_VERSION` and the package list in
  the Dockerfile. Re-test that `mod_lua` and `mod_curl` are still listed in
  the SignalWire repo for the new release.
