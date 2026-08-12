#!/usr/bin/env zsh

set -euo pipefail

APP_NAME="Switchyard"
PROJECT="Switchyard.xcodeproj"
SCHEME="Switchyard"
CONFIGURATION="Debug"
BUILD_DIR="build"

ACTIONS=("${@:-build}")

for ACTION in "${ACTIONS[@]}"; do
    case "$ACTION" in
        clean)
            xcodebuild clean \
                -project "$PROJECT" \
                -scheme "$SCHEME" \
                -configuration "$CONFIGURATION"
            ;;
        build)
            xcodebuild build \
                -project "$PROJECT" \
                -scheme "$SCHEME" \
                -configuration "$CONFIGURATION" \
                -derivedDataPath "$BUILD_DIR"
            ;;
        run)
            xcodebuild build \
                -project "$PROJECT" \
                -scheme "$SCHEME" \
                -configuration "$CONFIGURATION" \
                -derivedDataPath "$BUILD_DIR"
            APP_PATH=$(find "$BUILD_DIR" -name "$APP_NAME.app" -type d | head -1)
            if [[ -z "$APP_PATH" ]]; then
                echo "Error: $APP_NAME.app not found in $BUILD_DIR" >&2
                exit 1
            fi
            open "$APP_PATH"
            ;;
        terminate)
            if pkill -x "$APP_NAME"; then
                echo "$APP_NAME terminated."
            else
                echo "$APP_NAME is not running." >&2
            fi
            ;;
        test)
            xcodebuild test \
                -project "$PROJECT" \
                -scheme "$SCHEME" \
                -configuration "$CONFIGURATION" \
                -destination 'platform=macOS' \
                -derivedDataPath "$BUILD_DIR"
            ;;
        *)
            echo "Unknown action: $ACTION" >&2
            echo "Usage: $0 [clean|build|run|terminate|test] ..." >&2
            exit 1
            ;;
    esac
done
