# Custom prompts

The IVR plays its own bespoke recordings — there are **no stock FreeSWITCH
fallbacks**. Every prompt below has to exist for the call flow to work end
to end. Drop the recorded WAVs into this directory and they'll be mounted
into the FreeSWITCH container at `/var/lib/freeswitch/sounds/retromusicbox/en/` (see
the volume mount in `docker-compose.yml`).

## Format

- **8 kHz, 16-bit, mono PCM WAV** is what FreeSWITCH likes least-CPU; 16 kHz
  / 32 kHz / 48 kHz are also fine, FS will pick the closest match to the
  call's negotiated rate. If you only have one rate, pick 8 kHz — it works
  on every codec including G.711.
- Trim leading/trailing silence (~50 ms tops).
- Normalise around -3 dBFS so the prompts don't sit louder than the music
  videos when the channel is on the same audio bus.

The current workflow is to render takes from ElevenLabs as MP3 and then
convert in bulk with `scripts/convert-sounds.sh`, which calls ffmpeg with
the right resample / channel / codec flags. Drop fresh `.mp3` files into
`sounds/` (and `sounds/digits/`) and re-run the script — it ignores stray
files and only converts the named prompts the IVR actually plays.

## File list

### Dialogue prompts

Drop these directly under `sounds/` on the host.

| filename | env var (override) | script |
| --- | --- | --- |
| `welcome.wav` | `RMB_PROMPT_WELCOME` | "Welcome to Retro Music Box." |
| `enter-code.wav` | `RMB_PROMPT_ENTER_CODE` | "Enter the three-digit code for your video." |
| `invalid-code.wav` | `RMB_PROMPT_INVALID_CODE` | "Sorry, that's not a valid code. Please try again." |
| `you-entered.wav` | `RMB_PROMPT_YOU_ENTERED` | "You entered..." (read with a trailing pause — the digit clips play immediately after) |
| `press-to-confirm.wav` | `RMB_PROMPT_CONFIRM` | "Press 1 to confirm your selection, or press 2 to cancel." |
| `cancelled.wav` | `RMB_PROMPT_CANCELLED` | "Cancelled. Please enter a new selection." |
| `thanks.wav` | `RMB_PROMPT_THANKS` | "Thanks! Your video is on the way." |
| `all-lines-busy.wav` | `RMB_PROMPT_BUSY` | "All lines are currently busy. Please call back in a few minutes." |
| `limit-reached.wav` | `RMB_PROMPT_LIMIT_REACHED` | "Sorry, you've reached the limit of requests from your number for now. Please try again later." |
| `error.wav` | `RMB_PROMPT_ERROR` | "Sorry, something went wrong. Please call back later." |
| `goodbye.wav` | `RMB_PROMPT_GOODBYE` | "Thanks for calling Retro Music Box. Goodbye." |

### Digit clips

Drop these under `sounds/digits/` on the host. The script plays them in
sequence after `you-entered.wav` to read the caller's code back. Keep each
one tight (~400-500 ms total) and trim leading silence so the playback
flows naturally — `you entered… one… zero… zero… press one to confirm`.

| filename | script |
| --- | --- |
| `digits/0.wav` | "zero" |
| `digits/1.wav` | "one" |
| `digits/2.wav` | "two" |
| `digits/3.wav` | "three" |
| `digits/4.wav` | "four" |
| `digits/5.wav` | "five" |
| `digits/6.wav` | "six" |
| `digits/7.wav` | "seven" |
| `digits/8.wav` | "eight" |
| `digits/9.wav` | "nine" |

## Voice direction

The original 1990s "The Box" had a deliberately upbeat, slightly cheesy
American radio-DJ feel — "Welcome! What'll it be tonight?" energy. Aim for
that rather than corporate IVR flatness. A bit of room reverb and warmth
helps it sound like vintage broadcast rather than modern VoIP.

Record the dialogue prompts and the digit clips in the **same session, with
the same mic and processing chain**, so the digit reads sit naturally
between `you-entered.wav` and `press-to-confirm.wav`. Record each digit a
couple of times and pick the take whose pace and inflection matches a
mid-utterance read, not an isolated "one!" — the digits should sound like
they belong inside a sentence.

## What the IVR generates dynamically

Nothing — every word the caller hears is a recording you provide. The
artist and title are **not** spoken; they only appear on the channel's
on-screen overlay during the validated window. If you later want them
spoken too, that's a TTS add-on (`mod_flite` / `mod_tts_commandline` /
cloud TTS) that touches the Dockerfile, `config.lua`, and `run_confirm` in
`retromusicbox.lua`. See AGENTS.md for the rationale.

## Overriding individual paths

If you want to ship one of the prompts from a different location (e.g. a
shared house-style "all lines busy" clip), override the matching env var in
`docker-compose.yml`:

```yaml
environment:
  RMB_PROMPT_BUSY: /var/lib/freeswitch/sounds/retromusicbox/en/shared/lines-busy.wav
```

Use absolute paths so FreeSWITCH doesn't try to resolve them against its
sound prefix.
