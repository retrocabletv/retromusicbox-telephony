-- retromusicbox.lua
--
-- FreeSWITCH IVR front-end for retromusicbox.
-- Drives the service-agnostic IVR REST API exposed by rmbd. This script holds
-- no application state of its own; the session lives in rmbd and is created,
-- driven and torn down here over a handful of HTTP calls.
--
-- A request moves through four explicit states on the rmbd side:
--
--   dialling  -> caller is entering digits
--   validated -> backend confirmed the code resolves to a catalogue entry
--                and is waiting for the caller to press 1 (confirm) or
--                2 / * (cancel). The on-screen overlay shows the artist +
--                title during this window.
--   success   -> caller confirmed, request is on the queue ("Thanx!")
--   fail      -> unknown code or rejected by the queue ("Try again")
--
-- The REST contract is documented in the project README.

package.path = package.path .. ";/etc/freeswitch/scripts/?.lua"
local config = require("config")

local function log(level, msg)
  freeswitch.consoleLog(level, "[retromusicbox] " .. tostring(msg) .. "\n")
end

----------------------------------------------------------------------
-- HTTP via system curl. Avoids the lua-socket / lua-cjson / mod_lua
-- version-mismatch rabbit hole; rmbd's payloads are small and flat.
----------------------------------------------------------------------

local function shell_escape(s)
  return "'" .. tostring(s):gsub("'", [['\'']]) .. "'"
end

local function http_request(method, url, body)
  local tmp = os.tmpname()
  local cmd = string.format(
    "curl -sS -o %s -w '%%{http_code}' --max-time %d -X %s -H 'Content-Type: application/json'",
    shell_escape(tmp), config.http_timeout, method)
  if body then
    cmd = cmd .. " -d " .. shell_escape(body)
  end
  cmd = cmd .. " " .. shell_escape(url) .. " 2>/dev/null"

  local p = io.popen(cmd)
  local code_out = p and p:read("*a") or ""
  if p then p:close() end
  local status = tonumber((code_out or ""):match("(%d+)")) or 0

  local response = ""
  local f = io.open(tmp, "r")
  if f then response = f:read("*a") or ""; f:close() end
  os.remove(tmp)

  log("DEBUG", method .. " " .. url .. " -> " .. status)
  return status, response
end

local function json_object(tbl)
  local parts = {}
  for k, v in pairs(tbl) do
    local encoded
    if type(v) == "number" or type(v) == "boolean" then
      encoded = tostring(v)
    else
      encoded = '"' .. tostring(v):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
    end
    parts[#parts + 1] = '"' .. k .. '":' .. encoded
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function json_string(body, key)
  if not body then return nil end
  return body:match('"' .. key .. '"%s*:%s*"([^"]*)"')
end

----------------------------------------------------------------------
-- rmbd API wrappers
----------------------------------------------------------------------

local function create_session(caller_id)
  return http_request("POST", config.base_url .. "/api/ivr/sessions",
    json_object({ caller_id = caller_id or "" }))
end

local function send_digit(sid, digit)
  return http_request("POST",
    config.base_url .. "/api/ivr/sessions/" .. sid .. "/digit",
    json_object({ digit = digit }))
end

local function confirm_session(sid)
  return http_request("POST",
    config.base_url .. "/api/ivr/sessions/" .. sid .. "/confirm", nil)
end

local function cancel_session(sid)
  return http_request("POST",
    config.base_url .. "/api/ivr/sessions/" .. sid .. "/cancel", nil)
end

local function delete_session(sid)
  if not sid then return end
  http_request("DELETE", config.base_url .. "/api/ivr/sessions/" .. sid, nil)
end

----------------------------------------------------------------------
-- IVR flow
----------------------------------------------------------------------

-- Play the entered code back digit-by-digit using the bespoke per-digit
-- recordings in <digits_dir>. No mod_say_en — keeps the IVR voice consistent
-- with the rest of the prompts.
local function play_digits(sess, digits)
  for i = 1, #digits do
    sess:streamFile(config.digits_dir .. digits:sub(i, i) .. ".wav")
  end
end

-- Collect digits one at a time and POST each to rmbd as it's pressed, so the
-- on-screen overlay reveals them at the caller's actual dialling pace rather
-- than jumping from empty to all-three at once. The 3rd POST is the one that
-- triggers rmbd's catalogue lookup, so its response carries the final state
-- (`validated` / `fail`) — that's what gets returned as final_status/body.
--
-- Returns: digits, final_status, final_body
--   digits may be < 3 chars on timeout / hangup; in that case final_status is
--   nil. On the happy path digits is 3 chars and final_body holds the
--   validated-or-fail state from the 3rd POST.
local function collect_and_submit(sess, session_id)
  local digits = ""
  local final_status, final_body

  while sess:ready() and #digits < 3 do
    local d
    if #digits == 0 then
      -- First digit: play the enter-code prompt + collect 1 digit. DTMF
      -- pressed during the prompt interrupts it and counts as the digit.
      d = sess:playAndGetDigits(
        1, 1, 1,
        config.digit_timeout_ms,
        "",
        config.prompts.enter_code,
        config.prompts.invalid_code,
        "[0-9*#]",
        "rmb_d",
        0)
    else
      -- Subsequent digits: no prompt, just wait inter-digit timeout for the
      -- next keypress. Anything pressed during the gap between POSTs is
      -- already in the FreeSWITCH DTMF buffer when we get here.
      d = sess:getDigits(1, "", config.inter_digit_timeout_ms)
    end

    if not d or #d == 0 then
      log("WARNING", "timeout waiting for digit " .. (#digits + 1))
      return digits, nil, nil
    end

    log("INFO", "digit " .. (#digits + 1) .. ": " .. d)
    final_status, final_body = send_digit(session_id, d)
    if final_status < 200 or final_status >= 300 then
      log("ERR", "digit POST failed: " .. tostring(final_status))
      return digits, final_status, final_body
    end

    if d == "*" then
      -- rmbd's clearDigits handler resets the session to empty `dialling`;
      -- restart locally so the next iteration plays the prompt again.
      digits = ""
    elseif d == "#" then
      -- Caller submitted early. rmbd validated whatever partial digits were
      -- there and returned the result; bail out with that.
      return digits, final_status, final_body
    else
      digits = digits .. d
    end
  end

  return digits, final_status, final_body
end

-- run_confirm reads the validated selection back to the caller, prompts for
-- 1 (confirm) / 2 or * (cancel), and returns one of:
--   "success"       -> caller confirmed, request is on the queue
--   "cancelled"     -> caller cancelled, session is reusable in dialling state
--   "expired"       -> rmbd reaper dropped the session (404)
--   "rate_limited"  -> caller hit max_requests_per_caller_per_hour
--   "error"         -> something else went wrong
local function run_confirm(sess, session_id, digits, validated_body)
  local title  = json_string(validated_body, "title")  or ""
  local artist = json_string(validated_body, "artist") or ""
  log("INFO", string.format("validated: %s - %s, awaiting confirm", artist, title))

  -- Read back what the caller chose: "You entered ... <one> <zero> <zero>"
  -- followed by the static "press 1 to confirm" prompt. The on-screen overlay
  -- shows the full artist + title during this window; the IVR itself doesn't
  -- speak them (would need TTS — see AGENTS.md).
  sess:sleep(200)
  sess:streamFile(config.prompts.you_entered)
  play_digits(sess, digits)

  local choice = sess:playAndGetDigits(
    1, 1, 1,
    config.confirm_timeout_ms,
    "",
    config.prompts.press_to_confirm,
    config.prompts.press_to_confirm,
    "",
    "rmb_confirm",
    0)

  local cstatus, cbody
  if choice == "1" then
    cstatus, cbody = confirm_session(session_id)
  else
    -- 2, *, empty (timeout) or anything unexpected → cancel.
    if not choice or choice == "" then
      log("WARNING", "no confirm choice; treating as cancel")
    end
    cstatus, cbody = cancel_session(session_id)
  end

  if cstatus == 404 then
    log("WARNING", "session expired during confirm window")
    return "expired"
  end
  if cstatus < 200 or cstatus >= 300 then
    log("ERR", "confirm/cancel failed: " .. tostring(cstatus))
    return "error"
  end

  local result = json_string(cbody, "status") or ""
  if result == "success" then
    return "success"
  elseif result == "dialling" then
    return "cancelled"
  end
  -- "fail" at confirm time — typically queue.Add rejected it. Branch on
  -- reason_code so the caller gets a meaningful prompt instead of a generic
  -- "something went wrong". Unknown codes fall through to "error".
  local reason_code = json_string(cbody, "reason_code") or ""
  if reason_code == "rate_limited" then
    log("WARNING", "confirm rejected: rate_limited")
    return "rate_limited"
  end
  log("WARNING", "confirm rejected: " .. (reason_code ~= "" and reason_code or "unknown"))
  return "error"
end

local function handle_call(sess)
  sess:answer()
  sess:sleep(500)
  sess:streamFile(config.prompts.welcome)

  local caller = sess:getVariable("caller_id_number") or ""
  local status, body = create_session(caller)
  if status == 429 then
    log("WARNING", "rmbd reports all lines busy")
    sess:streamFile(config.prompts.all_lines_busy)
    return
  end
  if status < 200 or status >= 300 then
    log("ERR", "create session failed: " .. status .. " " .. body)
    sess:streamFile(config.prompts.error)
    return
  end

  local session_id = json_string(body, "session_id")
  if not session_id then
    log("ERR", "no session_id in response: " .. body)
    sess:streamFile(config.prompts.error)
    return
  end
  log("INFO", "ivr session " .. session_id .. " for caller " .. caller)

  local attempts = 0
  while sess:ready() and attempts < config.max_retries do
    attempts = attempts + 1
    local digits, final_status, final_body = collect_and_submit(sess, session_id)

    if #digits ~= 3 or not final_status then
      -- Timeout or hangup mid-dial. Reset rmbd's partial state for next attempt.
      log("WARNING", "incomplete code (attempt " .. attempts .. ", got " .. #digits .. ")")
      if sess:ready() then
        sess:streamFile(config.prompts.invalid_code)
        send_digit(session_id, "*")
      end
    elseif not (final_status >= 200 and final_status < 300) then
      log("ERR", "digit POST failed: " .. tostring(final_status))
      break
    else
      log("INFO", "caller entered " .. digits)
      local result = json_string(final_body, "status") or ""

      if result == "validated" then
        local outcome = run_confirm(sess, session_id, digits, final_body)

        if outcome == "success" then
          if sess:ready() then
            sess:streamFile(config.prompts.thanks)
            sess:streamFile(config.prompts.goodbye)
          end
          delete_session(session_id)
          return

        elseif outcome == "cancelled" then
          -- Session is back to empty `dialling`; reuse it for the next attempt.
          if sess:ready() then sess:streamFile(config.prompts.cancelled) end
          -- (loop continues — same session_id, attempts counter advances)

        elseif outcome == "expired" then
          if sess:ready() then sess:streamFile(config.prompts.error) end
          session_id = nil  -- already gone on the rmbd side
          break

        elseif outcome == "rate_limited" then
          -- Caller has hit their per-hour quota. No point looping — the
          -- limit is time-based, retrying in-call won't help.
          if sess:ready() then
            sess:streamFile(config.prompts.limit_reached)
            sess:streamFile(config.prompts.goodbye)
          end
          delete_session(session_id)
          return

        else  -- "error"
          if sess:ready() then sess:streamFile(config.prompts.error) end
          delete_session(session_id)
          return
        end

      elseif result == "fail" then
        local reason = json_string(final_body, "reason") or "unknown"
        log("WARNING", "code rejected: " .. reason)
        if sess:ready() then sess:streamFile(config.prompts.invalid_code) end
        -- The session has been finalised by rmbd; open a fresh one for the retry.
        delete_session(session_id)
        session_id = nil
        if attempts < config.max_retries and sess:ready() then
          local ns, nb = create_session(caller)
          if ns >= 200 and ns < 300 then
            session_id = json_string(nb, "session_id")
          end
          if not session_id then
            log("ERR", "failed to reopen session for retry")
            break
          end
        end

      else
        log("ERR", "unexpected status from submit: " .. result)
        break
      end
    end
  end

  if sess:ready() then sess:streamFile(config.prompts.goodbye) end
  delete_session(session_id)
end

----------------------------------------------------------------------
-- Entry point
----------------------------------------------------------------------

if session and session:ready() then
  local ok, err = pcall(handle_call, session)
  if not ok then
    freeswitch.consoleLog("ERR", "[retromusicbox] handler error: " .. tostring(err) .. "\n")
  end
  if session:ready() then session:hangup() end
end
