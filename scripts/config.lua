-- Runtime config for retromusicbox.lua. All values can be overridden via env vars
-- so the image can be reused without rebuilding. Prompt paths are resolved by
-- FreeSWITCH against its sound_prefix (voice + sample-rate dirs).

local function env(name, default)
  local v = os.getenv(name)
  if v == nil or v == "" then return default end
  return v
end

-- Bespoke prompts live in their own directory, mounted from the host's
-- sounds/ via docker-compose.yml. Absolute paths so FreeSWITCH doesn't try
-- to resolve them against its sound prefix. The trailing language segment
-- leaves room to add other locales (de, fr, ...) later without restructuring.
local PROMPT_DIR = "/var/lib/freeswitch/sounds/retromusicbox/en/"

return {
  base_url               = env("RMBD_URL", "http://rmbd:8080"),
  http_timeout           = tonumber(env("RMBD_HTTP_TIMEOUT", "15")),
  max_retries            = tonumber(env("RMB_MAX_RETRIES", "3")),
  digit_timeout_ms       = tonumber(env("RMB_DIGIT_TIMEOUT_MS", "10000")),
  inter_digit_timeout_ms = tonumber(env("RMB_INTER_DIGIT_TIMEOUT_MS", "5000")),
  -- How long to wait for the caller to press 1/2 at the confirmation prompt.
  -- Must be comfortably less than rmbd's ivr.confirm_ttl_seconds (default 15s)
  -- so the caller times out on our side first, while the rmbd session is still
  -- alive and cancellable.
  confirm_timeout_ms     = tonumber(env("RMB_CONFIRM_TIMEOUT_MS", "10000")),
  prompts = {
    welcome          = env("RMB_PROMPT_WELCOME",       PROMPT_DIR .. "welcome.wav"),
    enter_code       = env("RMB_PROMPT_ENTER_CODE",    PROMPT_DIR .. "enter-code.wav"),
    invalid_code     = env("RMB_PROMPT_INVALID_CODE",  PROMPT_DIR .. "invalid-code.wav"),
    you_entered      = env("RMB_PROMPT_YOU_ENTERED",   PROMPT_DIR .. "you-entered.wav"),
    press_to_confirm = env("RMB_PROMPT_CONFIRM",       PROMPT_DIR .. "press-to-confirm.wav"),
    cancelled        = env("RMB_PROMPT_CANCELLED",     PROMPT_DIR .. "cancelled.wav"),
    thanks           = env("RMB_PROMPT_THANKS",        PROMPT_DIR .. "thanks.wav"),
    all_lines_busy   = env("RMB_PROMPT_BUSY",          PROMPT_DIR .. "all-lines-busy.wav"),
    -- Played when rmbd reports reason_code=rate_limited on confirm — caller
    -- has hit max_requests_per_caller_per_hour. Falls back to the generic
    -- error prompt if the file is missing.
    limit_reached    = env("RMB_PROMPT_LIMIT_REACHED", PROMPT_DIR .. "limit-reached.wav"),
    error            = env("RMB_PROMPT_ERROR",         PROMPT_DIR .. "error.wav"),
    goodbye          = env("RMB_PROMPT_GOODBYE",       PROMPT_DIR .. "goodbye.wav"),
  },
  -- Per-digit recordings live in a subdir so the top of PROMPT_DIR stays tidy.
  -- The script plays them as <digits_dir>0.wav .. <digits_dir>9.wav.
  digits_dir = env("RMB_DIGITS_DIR", PROMPT_DIR .. "digits/"),
}
