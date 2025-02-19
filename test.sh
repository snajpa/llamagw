curl -X POST \
  http://127.0.0.1:30000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer example_api_key" \
  -d '{
    "model": "",
    "prompt": "Elaborate on SERPINs."
  }'
