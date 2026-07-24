#!/bin/sh
set -eu
KPZ=${1:?usage: validate-package.sh FILE.kpz}
unzip -t "$KPZ"
python3 "$(dirname "$0")/validate_source.py" --kpz "$KPZ"
BYTES=$(wc -c < "$KPZ" | tr -d ' ')
MEMBERS=$(unzip -Z1 "$KPZ" | wc -l | tr -d ' ')
SHA256=$(sha256sum "$KPZ" | awk '{print $1}')
echo "Bytes: $BYTES"
echo "Members: $MEMBERS"
echo "SHA-256: $SHA256"
echo 'Package validation passed'
