#!/bin/sh
set -e

echo "Waiting for midnight-node RPC to be ready..."

# Wait for RPC to be available (max 120 seconds)
RETRY=0
MAX_RETRY=120
until curl -s http://127.0.0.1:9944 > /dev/null 2>&1; do
  RETRY=$((RETRY+1))
  if [ $RETRY -ge $MAX_RETRY ]; then
    echo "RPC not available after $MAX_RETRY seconds, exiting"
    exit 1
  fi
  sleep 1
done

echo "Inserting AURA key..."
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"author_insertKey\",\"params\":[\"aura\",\"$AURA_PUB_KEY\",\"$AURA_PUB_KEY\"]}" \
  http://127.0.0.1:9944

echo "Inserting GRANDPA key..."
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"author_insertKey\",\"params\":[\"gran\",\"$GRANDPA_PUB_KEY\",\"$GRANDPA_PUB_KEY\"]}" \
  http://127.0.0.1:9944

echo "Inserting SIDECHAIN key..."
curl -s -X POST -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"author_insertKey\",\"params\":[\"crch\",\"$SIDECHAIN_PUB_KEY\",\"$SIDECHAIN_PUB_KEY\"]}" \
  http://127.0.0.1:9944

echo "Keys inserted successfully!"

# Keep running and re-check keys hourly
while true; do
  sleep 3600
  AURA_CHECK=$(curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"author_hasKey\",\"params\":[\"$AURA_PUB_KEY\",\"aura\"]}" \
    http://127.0.0.1:9944 | grep -o '"result":[^,}]*' | cut -d: -f2)
  if [ "$AURA_CHECK" != "true" ]; then
    echo "Keys missing, re-inserting..."
    curl -s -X POST -H "Content-Type: application/json" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"author_insertKey\",\"params\":[\"aura\",\"$AURA_PUB_KEY\",\"$AURA_PUB_KEY\"]}" \
      http://127.0.0.1:9944
    curl -s -X POST -H "Content-Type: application/json" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"author_insertKey\",\"params\":[\"gran\",\"$GRANDPA_PUB_KEY\",\"$GRANDPA_PUB_KEY\"]}" \
      http://127.0.0.1:9944
    curl -s -X POST -H "Content-Type: application/json" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"author_insertKey\",\"params\":[\"crch\",\"$SIDECHAIN_PUB_KEY\",\"$SIDECHAIN_PUB_KEY\"]}" \
      http://127.0.0.1:9944
    echo "Keys re-inserted"
  else
    echo "Keys still loaded, all good"
  fi
done
