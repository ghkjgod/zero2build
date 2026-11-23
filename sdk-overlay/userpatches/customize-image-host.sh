# Jammy's chromium-browser package is a launcher. Seed its signed ARM64 snap
# and dependencies so snapd can install the actual browser on first boot.
if [[ $BOARD == orangepizero2 && $RELEASE == jammy && $BUILD_DESKTOP == yes && -f $SRC/tmp/migration-complete ]]; then
    seed_root="$SRC/tmp/chromium-arm64-seed"
    target_seed="$SDCARD/var/lib/snapd/seed"
    [[ -f $seed_root/ready && -s $seed_root/seed/seed.yaml ]] || exit_with_error "Chromium ARM64 seed is not ready"
    [[ -x $SDCARD/usr/lib/snapd/snapd ]] || exit_with_error "snapd is missing from the target"
    if [[ -s $target_seed/seed.yaml ]] && ! cmp -s "$seed_root/seed/seed.yaml" "$target_seed/seed.yaml"; then
        exit_with_error "Target already has a different snap seed"
    fi
    mkdir -p "$target_seed" && cp -a "$seed_root/seed/." "$target_seed/" || exit_with_error "Cannot copy Chromium seed"
    display_alert "Chromium ARM64 seed staged" "stable" "info"
fi
