#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="$ROOT/dist/JunaidZaidiLibrary-DigitalCirculation-v0.1.0.kpz"
cd "$ROOT"
perl -MJSON -e 'local $/; decode_json(<>)' < Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/openapi.json
while IFS= read -r f; do test -f "$f" || { echo "Missing manifest file: $f" >&2; exit 1; }; done < MANIFEST
find Koha -type f -name '*.pm' | while IFS= read -r f; do perl -I. -c "$f" || exit 1; done
if grep -RIE '(BEGIN (RSA |OPENSSH )?PRIVATE KEY|client_secret[[:space:]]*[:=][[:space:]]*[^[:space:]]+|Authorization:[[:space:]]*Bearer)' Koha; then echo 'Potential secret found' >&2; exit 1; fi
if find Koha -type f \( -name '*.swp' -o -name '*~' -o -name '*.sqlite' -o -name '*.db' \) | grep .; then echo 'Rejected build artifact found' >&2; exit 1; fi
mkdir -p "$ROOT/dist"; rm -f "$OUT"
python3 scripts/build_kpz.py "$OUT" MANIFEST
unzip -t "$OUT"
echo "$OUT"
