curl -X POST \
  http://127.0.0.1:4567/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer example_api_key" \
  -d '{
    "model": "gemma-2-9b-instruct",
    "messages": [
      {
        "role": "user",
        "content": "Elaborate on SERPINs."
      }
    ]
  }'
