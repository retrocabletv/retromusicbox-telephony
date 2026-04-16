# retromusicbox-telephony

A FreeSWITCH-based voice front-end for [retromusicbox](https://github.com/alexkinch/retromusicbox)
— the project that recreates the 1990s "The Box" interactive music video
channel, where users dial a 3-digit code to queue a video that plays on a
full-screen channel output.

The retromusicbox backend (`rmbd`, written in Go) deliberately ships no SIP,
RTP or codec code. It exposes a small, service-agnostic IVR session REST API,
and any DTMF/voice front-end can drive it. **This repo is one such front-end.**
It lives standalone so the retromusicbox core stays provider-agnostic and so
this stack can be swapped out by anyone wanting Asterisk, Twilio, Jambonz, etc.

## What's in here

```
.
├── Dockerfile               # FreeSWITCH 1.10 + mod_lua + mod_curl + mod_say_en
├── docker-entrypoint.sh
├── docker-compose.yml       # standalone (host-net) for local dev
├── docker-compose.example.yml  # example: paired with rmbd in one stack
├── conf/
│   └── dialplan/public.xml  # routes any inbound DID into the Lua handler
├── scripts/
│   ├── retromusicbox.lua    # the IVR
│   └── config.lua           # env-driven runtime config
├── sounds/                  # the bespoke .wav prompts (see sounds/README.md)
└── .github/workflows/ci.yml # luacheck + xmllint
```

## How it talks to rmbd

A request moves through four explicit states on the rmbd side:

```
  dialling  -> caller is entering digits
  validated -> backend confirmed the code resolves to a catalogue entry
               and is waiting for the caller to press 1 (confirm) or
               2 / * (cancel). The on-screen overlay shows the artist
               and title during this window.
  success   -> caller confirmed, request is on the queue ("Thanx!")
  fail      -> unknown code or rejected by the queue ("Try again")
```

The Lua handler drives `rmbd` over its REST contract:

| method | path | purpose |
| --- | --- | --- |
| `POST` | `/api/ivr/sessions` | Create a session. **429** if `ivr.MaxConcurrent` (default 3) sessions are already active. |
| `POST` | `/api/ivr/sessions/{id}/digit` | Send a single digit. State-aware; backend auto-submits on the 3rd. |
| `POST` | `/api/ivr/sessions/{id}/submit` | Finalise dialling early (not used here — auto-submit is enough). |
| `POST` | `/api/ivr/sessions/{id}/confirm` | Commit a `validated` session to the queue. Used by the confirm step. |
| `POST` | `/api/ivr/sessions/{id}/cancel` | Roll a `validated` session back to empty `dialling`. Used by the cancel step. |
| `DELETE` | `/api/ivr/sessions/{id}` | Caller hung up / cleanup. |
| `GET` | `/api/ivr/sessions/{id}` | Inspect state. |

**The confirm window** (`validated` state) lives for `ivr.confirm_ttl_seconds`
on the rmbd side — default **15s**. The "press 1 to confirm" prompt plus
caller thinking time must fit inside that window, otherwise rmbd's reaper will
drop the session and the next confirm/cancel/digit POST returns 404. Our Lua
defaults give the caller a 10s window for the choice, comfortably inside the
backend TTL.

**A cancelled session is reusable.** After `/cancel` (or pressing 2 / * at the
confirm prompt), the session goes back to empty `dialling` and the handler
loops back to collect more digits *without* creating a new session. Creating a
fresh one would count against `ivr.MaxConcurrent` and may 429.

**Invalid codes go straight to `fail`.** They skip the confirm step entirely,
so the IVR plays "try again" immediately. The handler then deletes the failed
session and creates a new one for the retry — that path is fine because
`fail` sessions don't count against `MaxConcurrent`.

## Run

### From the published image (recommended)

Every release builds a multi-arch (`linux/amd64`, `linux/arm64`) image and
pushes it to GHCR. On a Linux host (bare-metal, VM, NAS):

```bash
curl -O https://raw.githubusercontent.com/alexkinch/retromusicbox-telephony/main/docker-compose.yml
docker compose up -d
```

The compose file uses `network_mode: host` and pulls
`ghcr.io/alexkinch/retromusicbox-telephony:latest`. Point `RMBD_URL` at
wherever rmbd is running (default `http://localhost:8080`, same host).

### Build from source

You need a [SignalWire Personal Access Token](https://developer.signalwire.com/freeswitch/FreeSWITCH-Explained/Installation/HOWTO-Create-a-SignalWire-Personal-Access-Token_67240087/)
to fetch the FreeSWITCH packages from the SignalWire Debian repo.

```bash
cp .env.example .env
$EDITOR .env       # set SIGNALWIRE_TOKEN
# In docker-compose.yml, swap the `image:` line for the `build:` block.
docker compose build
docker compose up
```

Either way, FreeSWITCH comes up listening on the external SIP profile
(UDP/TCP **5080**) with a wide RTP port range.

## Test it

1. Make sure `rmbd` is reachable at the URL in `RMBD_URL` (default
   `http://localhost:8080`). Verify with:
   ```bash
   curl -s -X POST http://localhost:8080/api/ivr/sessions \
     -H 'Content-Type: application/json' -d '{"caller_id":"test"}'
   ```
2. Point a softphone (Linphone, Zoiper, ...) at the FreeSWITCH container's
   external profile: SIP server `<host-ip>`, port `5080`, no auth, dial any
   number.
3. You should hear the welcome prompt; dial a 3-digit code; you'll get either
   the success or the rejection prompt depending on whether the code is valid.
4. Hang up at any time. The script's exit path always issues a `DELETE` to
   tear down the rmbd session.

Tail the container logs to watch the flow:

```bash
docker compose logs -f freeswitch | grep retromusicbox
```

## Configuration

All knobs are env vars, set in `docker-compose.yml` or `.env`:

| var | default | meaning |
| --- | --- | --- |
| `RMBD_URL` | `http://rmbd:8080` | base URL for the rmbd REST API |
| `RMBD_HTTP_TIMEOUT` | `15` | curl `--max-time` (seconds) |
| `RMB_MAX_RETRIES` | `3` | how many code attempts the caller gets per call |
| `RMB_DIGIT_TIMEOUT_MS` | `10000` | total time allowed to enter a 3-digit code |
| `RMB_INTER_DIGIT_TIMEOUT_MS` | `5000` | gap between digits before the collect aborts |
| `RMB_CONFIRM_TIMEOUT_MS` | `10000` | how long to wait for 1/2 at the confirm prompt — **must stay under rmbd's `ivr.confirm_ttl_seconds`** |
| `RMB_PROMPT_*` | `/var/lib/freeswitch/sounds/retromusicbox/en/<name>.wav` | override individual prompt paths — see `sounds/README.md` for the recording script |

> The IVR uses bespoke recordings only — there are no stock-FreeSWITCH
> fallbacks. See `sounds/README.md` for the script and audio format spec.
> Drop the `.wav` files into `sounds/` and the docker-compose volume mount
> exposes them inside the container.

## Design notes

- **Single-purpose.** This is an IVR for one app. There is no general-purpose
  dialplan framework here.
- **No state of its own.** The Lua handler holds no application state. The
  session lives in `rmbd`; this script just translates DTMF to REST.
- **Cleanup-safe.** Every exit path (success, fail, hangup, exception) issues a
  `DELETE` against the rmbd session.
- **Don't reach into rmbd.** The REST API is the contract. If it needs to
  change, raise it upstream rather than patching across repos.
- **Why system curl instead of luasocket?** mod_lua's bundled Lua version on
  the SignalWire Debian package doesn't always match the system `lua-socket` /
  `lua-cjson` packages. Shelling out to `curl` and doing tiny pattern-match
  JSON parsing for the handful of fields we read removes the whole class of
  Lua/library version mismatch failures and keeps the image small.
