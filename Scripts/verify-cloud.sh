#!/usr/bin/env bash
#
# Exercises the bring-your-own-key providers against the real thing.
#
# The unit tests are hermetic — they pin the wire as the providers *document* it. This is the
# other half: proof that the documentation was right. Nothing here can run in CI, because it
# needs credentials, which is exactly why it exists as a script you run rather than a test
# that silently never runs.
#
# Keys are never printed, and only ever read — from a file, or from the environment.
#
# The file is the better habit. A key on a command line lands in your shell history, and in
# the transcript of whatever tool ran it; a key in a 0600 file is typed once, by you, and
# read by nothing else:
#
#   mkdir -p ~/.config/silicon-optimizer && chmod 700 ~/.config/silicon-optimizer
#   read -rs KEY && printf '%s' "$KEY" > ~/.config/silicon-optimizer/gmi.key && unset KEY
#   chmod 600 ~/.config/silicon-optimizer/gmi.key
#
# `read -rs` does not echo what you type and does not enter history. Name the file after the
# provider: nvidia.key, open-router.key, gmi.key. Environment variables still work and take
# precedence — NVIDIA_API_KEY, OPENROUTER_API_KEY, GMI_API_KEY.
#
#   Keys: build.nvidia.com/settings/api-keys · openrouter.ai/keys · console.gmicloud.ai/apikeys
#
#   Scripts/verify-cloud.sh              # chat everywhere, plus GMI speech
#   Scripts/verify-cloud.sh --music      # …and a song, which takes 30–60s
#
# This spends real quota: one short completion per configured provider, one speech clip, and
# a song only if you ask for one.

set -uo pipefail

WITH_MUSIC=0
[[ "${1:-}" == "--music" ]] && WITH_MUSIC=1

pass=0; fail=0; skip=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
note() { printf '    %s\n' "$1"; }
none() { printf '  \033[33m–\033[0m %s\n' "$1"; skip=$((skip+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Pulls a value out of a JSON body without shelling a key into an argument list.
jqp() { python3 -c "$1" 2>/dev/null; }

# The environment wins; otherwise ~/.config/silicon-optimizer/<slug>.key if it is there.
# Trailing newlines are stripped, because an editor will add one and a bearer with a newline
# in it fails in a way that reads like a wrong key.
key_for() {               # env-var-name, slug
  local from_env="${!1:-}"
  if [[ -n "$from_env" ]]; then printf '%s' "$from_env"; return; fi
  local file="${HOME}/.config/silicon-optimizer/${2}.key"
  [[ -r "$file" ]] && tr -d '\r\n' < "$file"
}

# --- chat ---------------------------------------------------------------------------------
#
# One function for all three: they are the same API. That is the whole premise of the chat
# half of this feature, so if this loop needs a special case, something is wrong.

verify_chat() {           # name, base, key, model-filter
  local name="$1" base="$2" key="$3" filter="$4"

  local models
  models=$(curl -s --max-time 30 -H "Authorization: Bearer ${key}" "${base}/models")
  local count
  count=$(printf '%s' "$models" | jqp 'import json,sys; print(len(json.load(sys.stdin)["data"]))')
  if [[ -z "$count" ]]; then
    bad "${name}: GET /models did not return a list"
    note "$(printf '%s' "$models" | head -c 200)"
    return
  fi
  ok "${name}: ${count} models listed"

  # Prefer a model matching the filter, else the first one. Discovered, never assumed —
  # the same rule the app follows.
  local model
  model=$(printf '%s' "$models" | jqp "
import json,sys
d = json.load(sys.stdin)['data']
m = [x['id'] for x in d if '${filter}' in x['id'].lower()] or [x['id'] for x in d]
print(m[0] if m else '')")
  if [[ -z "$model" ]]; then bad "${name}: no usable model id"; return; fi
  note "using ${model}"

  local body reply
  body=$(python3 -c "
import json
print(json.dumps({'model': '${model}',
                  'messages': [{'role': 'user', 'content': 'Reply with exactly: pong'}],
                  'max_tokens': 16}))")
  reply=$(curl -s --max-time 120 -X POST "${base}/chat/completions" \
    -H "Authorization: Bearer ${key}" -H 'Content-Type: application/json' -d "$body")

  local text
  text=$(printf '%s' "$reply" | jqp "
import json,sys
d = json.load(sys.stdin)
print((d.get('choices') or [{}])[0].get('message', {}).get('content', '').strip()[:60])")
  if [[ -n "$text" ]]; then
    ok "${name}: chat answered — “${text}”"
  else
    bad "${name}: chat returned no content"
    note "$(printf '%s' "$reply" | head -c 300)"
  fi
}

# --- GMI's audio queue --------------------------------------------------------------------
#
# The part the hermetic tests cannot prove. Payload shapes here were read out of GMI's docs
# and never sent anywhere: speech quotes its numerics and music does not, which is the kind
# of detail that is either right or embarrassing.

verify_audio() {          # label, model, payload-json
  local label="$1" model="$2" payload="$3"
  local queue="https://console.gmicloud.ai/api/v1/ie/requestqueue/apikey/requests"

  local body submitted request_id
  body=$(python3 -c "
import json
print(json.dumps({'model': '${model}', 'payload': json.loads('''${payload}''')}))")
  submitted=$(curl -s --max-time 60 -X POST "$queue" \
    -H "Authorization: Bearer ${GMI_KEY}" -H 'Content-Type: application/json' -d "$body")

  request_id=$(printf '%s' "$submitted" | jqp 'import json,sys; print(json.load(sys.stdin).get("request_id",""))')
  if [[ -z "$request_id" ]]; then
    bad "${label}: submit rejected"
    note "$(printf '%s' "$submitted" | head -c 300)"
    return
  fi
  ok "${label}: accepted (${request_id})"

  # Terminal states are success / failed / cancelled — poll on anything else.
  local waited=0 status='' out=''
  while (( waited < 300 )); do
    out=$(curl -s --max-time 30 -H "Authorization: Bearer ${GMI_KEY}" "${queue}/${request_id}")
    status=$(printf '%s' "$out" | jqp 'import json,sys; print(json.load(sys.stdin).get("status","").lower())')
    case "$status" in
      success|succeeded|failed|error|cancelled|canceled) break ;;
    esac
    sleep 5; waited=$((waited+5))
    printf '    …%s (%ss)\r' "${status:-waiting}" "$waited"
  done
  printf '\033[K'

  if [[ "$status" != "success" && "$status" != "succeeded" ]]; then
    bad "${label}: finished as '${status:-timed out}'"
    note "$(printf '%s' "$out" | head -c 300)"
    return
  fi

  # All three spellings, the way the app reads them.
  local url
  url=$(printf '%s' "$out" | jqp "
import json,sys
o = json.load(sys.stdin).get('outcome') or {}
found = [o['audio_url']] if isinstance(o.get('audio_url'), str) else []
for k in ('media_urls','medias'):
    for e in (o.get(k) or []):
        if isinstance(e, dict) and e.get('url'): found.append(e['url'])
print(found[0] if found else '')")
  if [[ -n "$url" ]]; then
    ok "${label}: audio returned"
    note "${url:0:90}"
  else
    bad "${label}: reported success but carried no audio URL"
    note "$(printf '%s' "$out" | head -c 300)"
  fi
}

# --- run ----------------------------------------------------------------------------------

NVIDIA_KEY=$(key_for NVIDIA_API_KEY nvidia)
OPENROUTER_KEY=$(key_for OPENROUTER_API_KEY open-router)
GMI_KEY=$(key_for GMI_API_KEY gmi)

section 'NVIDIA'
if [[ -n "$NVIDIA_KEY" ]]; then
  verify_chat 'NVIDIA' 'https://integrate.api.nvidia.com/v1' "$NVIDIA_KEY" 'nemotron'
else
  none 'no NVIDIA key (env NVIDIA_API_KEY or ~/.config/silicon-optimizer/nvidia.key)'
fi

section 'OpenRouter'
if [[ -n "$OPENROUTER_KEY" ]]; then
  verify_chat 'OpenRouter' 'https://openrouter.ai/api/v1' "$OPENROUTER_KEY" 'minimax'
else
  none 'no OpenRouter key (env OPENROUTER_API_KEY or ~/.config/silicon-optimizer/open-router.key)'
fi

section 'GMI Cloud'
if [[ -n "$GMI_KEY" ]]; then
  verify_chat 'GMI Cloud' 'https://api.gmi-serving.com/v1' "$GMI_KEY" 'minimax'

  verify_audio 'speech' 'minimax-tts-speech-2.6-turbo' \
    '{"text": "The wire contract holds.", "voice_id": "English_expressive_narrator", "format": "mp3", "speed": "1"}'

  if (( WITH_MUSIC )); then
    verify_audio 'music' 'minimax-music-3.0' \
      '{"lyrics": "[verse]\\nSilicon hums in the dark\\n[chorus]\\nEverything runs where you are", "prompt": "warm lo-fi, mellow piano", "format": "mp3", "sample_rate": 44100}'
  else
    none 'music (pass --music; it takes 30-60s)'
  fi
else
  none 'no GMI key (env GMI_API_KEY or ~/.config/silicon-optimizer/gmi.key)'
fi

printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$pass" "$fail" "$skip"
(( fail == 0 ))
