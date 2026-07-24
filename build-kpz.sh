#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RELEASE_SUFFIX=${1:-}
case "$RELEASE_SUFFIX" in
    '') ;;
    *[!A-Za-z0-9.-]*|[.-]*)
        echo 'Release suffix must start with an alphanumeric character and contain only letters, digits, dots, or hyphens.' >&2
        exit 1
        ;;
esac

VERSION=$(sed -n "s/^our \\\$VERSION[[:space:]]*=[[:space:]]*'\\([^']*\\)';/\\1/p" \
    "$ROOT/Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation.pm")
test -n "$VERSION" || { echo 'Could not determine plugin version from the main module' >&2; exit 1; }
SUFFIX=
test -z "$RELEASE_SUFFIX" || SUFFIX="-$RELEASE_SUFFIX"
OUT="$ROOT/dist/JunaidZaidiLibrary-DigitalCirculation-v$VERSION$SUFFIX.kpz"

cd "$ROOT"
python3 scripts/validate_source.py
perl -MJSON -e 'local $/; decode_json(<>)' < Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation/openapi.json
while IFS= read -r file; do
    test -f "$file" || { echo "Missing manifest file: $file" >&2; exit 1; }
done < MANIFEST
find Koha -type f -name '*.pm' | while IFS= read -r file; do
    perl -I. -c "$file" || exit 1
done
if grep -RIE '(BEGIN (RSA |OPENSSH )?PRIVATE KEY|client_secret[[:space:]]*[:=][[:space:]]*[^[:space:]]+|Authorization:[[:space:]]*Bearer)' Koha; then
    echo 'Potential secret found' >&2
    exit 1
fi
if find Koha -type f \( -name '*.swp' -o -name '*~' -o -name '*.sqlite' -o -name '*.db' \) | grep .; then
    echo 'Rejected build artifact found' >&2
    exit 1
fi
mkdir -p "$ROOT/dist"
if test -e "$OUT"; then
    echo "Output already exists; preserve or archive it before rebuilding: $OUT" >&2
    exit 1
fi

python3 scripts/build_kpz.py "$OUT" MANIFEST
unzip -t "$OUT"
python3 scripts/validate_source.py --kpz "$OUT"
BYTES=$(wc -c < "$OUT" | tr -d ' ')
MEMBERS=$(unzip -Z1 "$OUT" | wc -l | tr -d ' ')
SHA256=$(sha256sum "$OUT" | awk '{print $1}')
echo "Artifact: $OUT"
echo "Bytes: $BYTES"
echo "Members: $MEMBERS"
echo "SHA-256: $SHA256"
