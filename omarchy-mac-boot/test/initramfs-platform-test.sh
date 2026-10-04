#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/base-test.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/detector" "$work/conf"
printf '#!/bin/bash\nprintf "/lib/modules/fixture/%%s.ko\\n" "${@: -1}"\n' >"$work/bin/modinfo"
cat >"$work/detector/omarchy-hw-platform" <<'STUB'
#!/bin/bash
[[ $PLATFORM != "error" ]] || exit 3
echo "$PLATFORM"
STUB
chmod +x "$work/bin/"* "$work/detector/"*
printf 'KEYMAP=dk-latin1\nXKBLAYOUT=dk\n' >"$work/vconsole"
for file in "$ROOT"/files/etc/mkinitcpio.conf.d/*.conf; do
  sed "s|/etc/vconsole.conf|$work/vconsole|g" "$file" >"$work/conf/${file##*/}"
done
compose() {
  local platform=$1 hooks=$2 path=$work/bin
  [[ $platform == "missing" ]] || path=$work/detector:$path
  PLATFORM=$platform KERNELVERSION=fixture PATH=$path /bin/bash -c '
    set -e
    read -ra HOOKS <<<"$2"
    MODULES=(existing-module) FILES=(existing-file)
    for configuration_file in "$1"/*.conf; do source "$configuration_file"; done
    printf "HOOKS=%s\nMODULES=%s\nFILES=%s\n" "${HOOKS[*]}" "${MODULES[*]}" "${FILES[*]}"
  ' -- "$work/conf" "$hooks"
}
baseline='base systemd plymouth keyboard sd-vconsole block filesystems fsck'
expected=$'HOOKS=base systemd plymouth keyboard sd-vconsole block filesystems fsck\nMODULES=existing-module\nFILES=existing-file'
for platform in generic generic-aarch64 qualcomm; do
  composition_output=$(compose "$platform" "$baseline") || fail 'off-Apple configuration sources successfully'
  # shellcheck disable=SC2053 # This literal fixture contains no glob syntax.
  [[ $composition_output == $expected ]] || fail 'available Apple modules do not alter another platform' "$composition_output"
done
pass 'all package drop-ins leave unrelated platforms unchanged even with available HID modules'
for platform in apple-silicon missing; do
  composition_output=$(compose "$platform" "$baseline") || fail 'Apple and older-runtime configurations source successfully'
  [[ $composition_output == *'omarchy-vendorfw omarchy-mac-encrypt sd-encrypt filesystems'* ]] || fail 'Apple roots retain firmware and unlock hooks' "$composition_output"
  [[ $composition_output == *'hid_apple hid_magicmouse'* && $composition_output == *'FILES=existing-file' ]] || fail 'early input is added and explicit file ownership stays shared' "$composition_output"
done
pass 'Apple roots and a missing detector retain firmware, encryption and early input'
marked_baseline=${baseline/ filesystems / asahi filesystems }
composition_output=$(compose generic-aarch64 "$marked_baseline") || fail 'an asahi root composes away from Apple hardware'
[[ $composition_output == *"omarchy-vendorfw"* && $composition_output == *"hid_apple"* ]] || fail 'the asahi marker retains vendor firmware and early input' "$composition_output"
composition_output=$(compose apple-silicon "$baseline asahi omarchy-vendorfw asahi") || fail 'existing hooks compose successfully'
read -ra composed_hooks <<<"${composition_output%%$'\n'*}"
asahi_count=0
for hook in "${composed_hooks[@]}"; do
  [[ $hook != "asahi" ]] || asahi_count=$((asahi_count + 1))
done
(( asahi_count == 1 )) || fail 'an existing asahi hook is not duplicated' "$composition_output"
if compose error "$baseline asahi" >"$work/output" 2>&1; then
  fail 'a failing detector stops the build even on a marked root'
fi
pass 'marked roots retain Apple behavior and detector failures stop composition'

already_composed='base systemd plymouth keyboard sd-vconsole block asahi omarchy-vendorfw omarchy-mac-encrypt sd-encrypt filesystems fsck'
composition_output=$(compose apple-silicon "$already_composed") || fail 'a composed Apple root sources again'
# shellcheck disable=SC2053 # This independently specified hook sequence has no glob syntax.
[[ ${composition_output%%$'\n'*} == HOOKS=$already_composed ]] || fail 'recomposition preserves firmware before the encryption hooks' "$composition_output"
pass 'an already-composed root retains the firmware and unlock hook order'
