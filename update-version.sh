#!/bin/bash
# Update SPT and Fika versions in project files, and optionally build/deploy

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE_TAG="fika-spt-server-docker-arm:local"
DEPLOY_PATH="~/fika-spt-server-docker-arm"

# Parse arguments
DRY_RUN=false
BUILD=false
DEPLOY_HOST=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -b|--build)
            BUILD=true
            shift
            ;;
        -d|--deploy)
            BUILD=true
            DEPLOY_HOST="$2"
            shift 2
            ;;
        --deploy-path)
            DEPLOY_PATH="$2"
            shift 2
            ;;
        --image-tag)
            IMAGE_TAG="$2"
            shift 2
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Update SPT and Fika versions in project files, and optionally build the
arm64 image and deploy it to a remote host over SSH.

Options:
  -n, --dry-run          Show what would be updated without making changes
  -b, --build            Also build the arm64 image locally after updating versions
  -d, --deploy HOST      Build, then transfer and deploy to HOST over SSH (implies --build)
                         HOST is an ssh target, e.g. user@your-vps-ip
      --deploy-path PATH Remote directory containing docker-compose.yml
                         (default: ${DEPLOY_PATH})
      --image-tag TAG    Local image tag to build (default: ${IMAGE_TAG})
  -h, --help             Show this help message

Examples:
  $0                                    # Update version files only
  $0 --dry-run                          # Check what would be updated
  $0 --build                            # Update, then build the arm64 image locally
  $0 --deploy user@your-vps-ip          # Update, build, and deploy to a VPS
  $0 --deploy user@vps --deploy-path ~/fika-server
EOF
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            echo "Run '$0 --help' for usage" >&2
            exit 1
            ;;
    esac
done

# Check for required commands
REQUIRED_CMDS=(curl jq)
if [ "$BUILD" = true ]; then
    REQUIRED_CMDS+=(docker)
fi
if [ -n "$DEPLOY_HOST" ]; then
    REQUIRED_CMDS+=(ssh)
fi
for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Missing required command: $cmd" >&2
        exit 1
    fi
done

# Get latest versions
echo "Fetching latest versions..."

chmod +x "$SCRIPT_DIR/scripts/get-spt-version.sh"
SPT_VERSION=$("$SCRIPT_DIR/scripts/get-spt-version.sh" latest)
FIKA_VERSION=$(curl -s https://api.github.com/repos/project-fika/Fika-Server-CSharp/releases/latest | jq -r '.tag_name' | sed 's/^v//')

if [ -z "$SPT_VERSION" ] || [ -z "$FIKA_VERSION" ] || [ "$FIKA_VERSION" = "null" ]; then
    echo "Error: Failed to fetch versions" >&2
    exit 1
fi

echo "Latest versions:"
echo "  SPT:  $SPT_VERSION"
echo "  Fika: $FIKA_VERSION"
echo

if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: Would update:"
    echo "  - Dockerfile"
    echo "  - Dockerfile.multiarch"
    echo "  - entrypoint.sh"
    if [ "$BUILD" = true ]; then
        echo "DRY RUN: Would build image: $IMAGE_TAG"
    fi
    if [ -n "$DEPLOY_HOST" ]; then
        echo "DRY RUN: Would deploy $IMAGE_TAG to $DEPLOY_HOST:$DEPLOY_PATH"
    fi
    exit 0
fi

# Update files
echo "Updating files..."

sed -i "s/^ARG SPT_VERSION=.*/ARG SPT_VERSION=${SPT_VERSION}/" "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR/Dockerfile.multiarch"
sed -i "s/^ARG FIKA_VERSION=.*/ARG FIKA_VERSION=${FIKA_VERSION}/" "$SCRIPT_DIR/Dockerfile" "$SCRIPT_DIR/Dockerfile.multiarch"

sed -i "s/^spt_version=\${SPT_VERSION:-.*\}/spt_version=\${SPT_VERSION:-${SPT_VERSION}\}/" "$SCRIPT_DIR/entrypoint.sh"
sed -i "s/^fika_version=\${FIKA_VERSION:-.*\}/fika_version=\${FIKA_VERSION:-${FIKA_VERSION}\}/" "$SCRIPT_DIR/entrypoint.sh"

echo "✓ Updated successfully"
echo
echo "Updated to:"
echo "  SPT:  $SPT_VERSION"
echo "  Fika: $FIKA_VERSION"

if [ "$BUILD" = true ]; then
    echo
    echo "Building arm64 image: $IMAGE_TAG"
    docker buildx build -f "$SCRIPT_DIR/Dockerfile.multiarch" --platform linux/arm64 \
        --build-arg SPT_VERSION="$SPT_VERSION" \
        --build-arg FIKA_VERSION="$FIKA_VERSION" \
        -t "$IMAGE_TAG" --load "$SCRIPT_DIR"
    echo "✓ Build complete: $IMAGE_TAG"
fi

if [ -n "$DEPLOY_HOST" ]; then
    echo
    echo "Deploying $IMAGE_TAG to $DEPLOY_HOST:$DEPLOY_PATH"
    docker save "$IMAGE_TAG" | ssh "$DEPLOY_HOST" 'docker load'
    ssh "$DEPLOY_HOST" "cd $DEPLOY_PATH && docker compose up -d --force-recreate"
    echo "✓ Deployed and restarted on $DEPLOY_HOST"
fi
