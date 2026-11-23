#!/bin/bash
# Build a signed ARM64 classic-system seed with the Ubuntu snap tooling.
set -euo pipefail
cd /root/orangepi
export TMPDIR=$PWD/tmp
seed="$TMPDIR/chromium-arm64-seed"
if [[ -f $seed/ready ]]; then exit 0; fi
mkdir -p "$seed" "$TMPDIR/snap-client"
cd "$TMPDIR/snap-client"
export PATH="$PWD/usr/bin:$PATH"
packages=()
command -v snap || packages+=(snapd)
command -v unsquashfs || packages+=(squashfs-tools)
if (( ${#packages[@]} )); then
    apt-get -qq update
    for pkg in "${packages[@]}"; do
        version=$(LC_ALL=C apt-cache policy "$pkg" | awk '/Candidate:/ {print $2}')
        [[ -n $version && $version != '(none)' ]]
        apt-get download "$pkg=$version"
        dpkg-deb -x "${pkg}_${version//:/%3a}_amd64.deb" .
    done
fi
command -v unsquashfs
if ldd "$(command -v unsquashfs)" | grep -F 'not found'; then exit 1; fi
curl -fsSL --retry 3 --max-time 60 -o generic-classic.model https://raw.githubusercontent.com/canonical/models/main/generic-classic.model
test "$(git hash-object generic-classic.model)" = 289f8d3ab0c8b6b99208678b28c432bd88773ff6
target=$(mktemp -d "$seed/work.XXXXXXXX")
# Classic seeds need all bases and default content providers passed explicitly.
# Resolve them from the Store's *arm64 stable* manifests, including providers'
# own bases. Let snap download and verify the actual revisions and assertions.
python3 - "$target/snaps.list" <<'PY'
import json, re, sys
from urllib.request import Request, urlopen

# A classic seed must also contain its package manager. A coreXX runtime
# is a base for applications and does not satisfy this seed requirement.
pending, seen = ['chromium', 'snapd'], set()
with open(sys.argv[1], 'w') as out:
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        seen.add(name)
        if not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*', name):
            sys.exit(f'Invalid provider name: {name}')
        url = f'https://api.snapcraft.io/v2/snaps/info/{name}?fields=base,snap-yaml,revision,name,version'
        req = Request(url, headers={'Snap-Device-Series':'16', 'Snap-Device-Architecture':'arm64'})
        with urlopen(req, timeout=45) as r:
            info = json.load(r)
        track = info.get('default-track') or 'latest'
        row = next((s for s in info['channel-map'] if s['channel']['architecture'] == 'arm64'
                    and s['channel']['track'] == track and s['channel']['risk'] == 'stable'), None)
        if row is None or not row.get('snap-yaml'):
            sys.exit(f'No ARM64 stable manifest for {name}')
        deps = set(re.findall(r'(?m)^\s*default-provider:\s*[\'"]?([a-z0-9-]+)', row['snap-yaml']))
        if row.get('base') not in ('none', None, ''):
            deps.add(row['base'])
        print(f'{name} (arm64/stable {row["revision"]}): {", ".join(sorted(deps))}', flush=True)
        pending.extend(sorted(deps - seen))
        print(name, int(row['revision']), file=out)
PY
snap_args=()
tree="$target/var/lib/snapd/seed"
mkdir -p "$tree/snaps"
while read -r name revision; do
    snap_args+=("--snap=$name")
    file="${name}_${revision}.snap"
    for cached in "$seed"/work.*/var/lib/snapd/seed/snaps/"$file"; do
        [[ -s $cached && $cached != "$tree/snaps/$file" ]] || continue
        # Store downloads check the size and SHA3-384 of an existing blob.
        ln "$cached" "$tree/snaps/$file"
        break
    done
done < "$target/snaps.list"
snap prepare-image --classic --arch=arm64 "${snap_args[@]}" --channel=stable generic-classic.model "$target"
test -s "$tree/seed.yaml"
snap debug validate-seed "$tree/seed.yaml"
shopt -s nullglob
snaps=("$tree"/snaps/chromium_*.snap)
(( ${#snaps[@]} == 1 ))
unsquashfs -cat "${snaps[0]}" meta/snap.yaml | awk '/^architectures:/ { a=1; next } a && /^[[:space:]]*-[[:space:]]+arm64$/ { ok=1 } END {exit !ok}'
mv "$tree" "$seed/seed"
touch "$seed/ready"
