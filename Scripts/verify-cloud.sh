#!/usr/bin/env bash
#
# Exercises the bring-your-own-key providers against the real thing.
#
# The unit tests are hermetic — they pin the wire as the providers *document* it. This is the
# other half: proof that the documentation was right. Nothing here can run in CI, because it
# needs credentials, which is exactly why it exists as a script you run rather than a test
# that silently never runs.
#
# Keys come from the environment and are never printed. Set only the ones you have:
#
#   export NVIDIA_API_KEY=nvapi-…        # free, no card — build.nvidia.com/settings/api-keys
#   export OPENROUTER_API_KEY=sk-or-…    # openrouter.ai/keys
#   export GMI_API_KEY=…                 # console.gmicloud.ai/apikeys
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
    -H "Authorization: Bearer ${GMI_API_KEY}" -H 'Content-Type: application/json' -d "$body")

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
    out=$(curl -s --max-time 30 -H "Authorization: Bearer ${GMI_API_KEY}" "${queue}/${request_id}")
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

section 'NVIDIA'
if [[ -n "${NVIDIA_API_KEY:-}" ]]; then
  verify_chat 'NVIDIA' 'https://integrate.api.nvidia.com/v1' "$NVIDIA_API_KEY" 'nemotron'
else
  none 'NVIDIA_API_KEY not set'
fi

section 'OpenRouter'
if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
  verify_chat 'OpenRouter' 'https://openrouter.ai/api/v1' "$OPENROUTER_API_KEY" 'minimax'
else
  none 'OPENROUTER_API_KEY not set'
fi

section 'GMI Cloud'
if [[ -n "${GMI_API_KEY:-}" ]]; then
  verify_chat 'GMI Cloud' 'https://api.gmi-serving.com/v1' "$GMI_API_KEY" 'minimax'

  verify_audio 'speech' 'minimax-tts-speech-2.6-turbo' \
    '{"text": "The wire contract holds.", "voice_id": "English_expressive_narrator", "format": "mp3", "speed": "1"}'

  if (( WITH_MUSIC )); then
    verify_audio 'music' 'minimax-music-3.0' \
      '{"lyrics": "[verse]\\nSilicon hums in the dark\\n[chorus]\\nEverything runs where you are", "prompt": "warm lo-fi, mellow piano", "format": "mp3", "sample_rate": 44100}'
  else
    none 'music (pass --music; it takes 30-60s)'
  fi
else
  none 'GMI_API_KEY not set'
fi

printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$pass" "$fail" "$skip"
(( fail == 0 ))
