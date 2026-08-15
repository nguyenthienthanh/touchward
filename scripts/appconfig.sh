# Single source of truth for the app's identity.
#
# Everything downstream — the bundle name, the executable, Info.plist, the code signature,
# the installed copy and the disk image — is derived from these four values, so renaming
# the app is one edit here rather than a hunt through scripts and plists.
#
# Changing APP_NAME or BUNDLE_ID makes macOS treat this as a different app: TCC grants for
# the old identity do not carry over and Accessibility / Input Monitoring must be granted
# again. Change them deliberately, not casually.

APP_NAME="Touchward"
BUNDLE_ID="com.ethannguyen.touchward"
VERSION="1.0.0"
BUILD_NUMBER="1"

# The Swift product name. Fixed, and independent of the display name.
PRODUCT="touchward"

# Where finished artefacts land. Not the SwiftPM build directory.
OUT_DIR="Artifacts"
