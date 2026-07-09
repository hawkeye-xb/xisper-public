#!/bin/bash
# Quick provider key validation - paste your actual keys below and run
# Usage: bash test-keys.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo "=== AI Provider Key Validation ==="
echo ""

test_openai_compat() {
  local name="$1" url="$2" key="$3" model="$4"
  if [ -z "$key" ]; then
    echo -e "${YELLOW}SKIP${NC} $name — no key provided"
    return
  fi
  local resp
  resp=$(curl -s --max-time 10 -X POST "$url" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $key" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":3}")
  if echo "$resp" | grep -q '"choices"'; then
    echo -e "${GREEN}OK${NC}   $name ($model)"
  else
    local err
    err=$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',{}).get('message','') or d.get('error',''))" 2>/dev/null || echo "$resp")
    echo -e "${RED}FAIL${NC} $name — $err"
  fi
}

# Fill in your keys here (same values you used in `wrangler secret put`)
GROQ="${GROQ_API_KEY:-}"
GEMINI="${GEMINI_API_KEY:-}"
DEEPSEEK="${DEEPSEEK_API_KEY:-}"
ZHIPU="${ZHIPU_API_KEY:-}"
ALIBABA="${ALIBABA_API_KEY:-}"

test_openai_compat "Groq"     "https://api.groq.com/openai/v1/chat/completions"          "$GROQ"     "llama-3.3-70b-versatile"
test_openai_compat "Gemini"   "https://generativelanguage.googleapis.com/v1beta/chat/completions" "$GEMINI"   "gemini-2.0-flash"
test_openai_compat "DeepSeek" "https://api.deepseek.com/chat/completions"                 "$DEEPSEEK" "deepseek-chat"
test_openai_compat "Zhipu"    "https://open.bigmodel.cn/api/paas/v4/chat/completions"     "$ZHIPU"    "glm-4-flash"

echo ""
echo "--- Alibaba ASR Key (WebSocket-based, simple HTTP check) ---"
if [ -z "$ALIBABA" ]; then
  echo -e "${YELLOW}SKIP${NC} Alibaba ASR — no key provided"
else
  asr_resp=$(curl -s --max-time 10 -X POST "https://dashscope.aliyuncs.com/api/v1/services/aigc/text-generation/generation" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ALIBABA" \
    -d '{"model":"qwen-turbo","input":{"messages":[{"role":"user","content":"hi"}]},"parameters":{"max_tokens":3}}')
  if echo "$asr_resp" | grep -q '"output"'; then
    echo -e "${GREEN}OK${NC}   Alibaba (DashScope key valid)"
  elif echo "$asr_resp" | grep -q '"InvalidApiKey"'; then
    echo -e "${RED}FAIL${NC} Alibaba — Invalid API Key"
  else
    echo -e "${YELLOW}????${NC} Alibaba — $(echo "$asr_resp" | head -c 200)"
  fi
fi

echo ""
echo "Done. Export your keys as env vars before running, e.g.:"
echo "  export GROQ_API_KEY=gsk_xxx DEEPSEEK_API_KEY=sk-xxx ..."
echo "  bash test-keys.sh"
