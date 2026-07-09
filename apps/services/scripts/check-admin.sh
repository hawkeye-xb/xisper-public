#!/bin/bash

# Check if a user has admin role in D1 database
# Usage: ./check-admin.sh <email>

if [ -z "$1" ]; then
  echo "Usage: ./check-admin.sh <email>"
  echo "Example: ./check-admin.sh user@example.com"
  exit 1
fi

EMAIL="$1"

echo "Checking admin role for: $EMAIL"
echo "---"

wrangler d1 execute xisper-dev --command "SELECT id, email, role, tier, created_at FROM users WHERE email LIKE '%$EMAIL%' ORDER BY created_at DESC LIMIT 5;"
