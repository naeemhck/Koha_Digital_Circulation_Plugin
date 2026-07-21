#!/bin/sh
set -eu
KPZ=${1:?usage: validate-package.sh FILE.kpz}
unzip -t "$KPZ"
unzip -Z1 "$KPZ" | grep -Eq '^Koha/Plugin/Com/JunaidZaidiLibrary/DigitalCirculation\.pm$'
if unzip -Z1 "$KPZ" | grep -E '(^|/)(\.git|node_modules|vendor|coverage|test-results|__pycache__)(/|$)|\.(env|db|sqlite|swp)$|~$'; then echo 'Forbidden package content' >&2; exit 1; fi
echo 'Package validation passed'
