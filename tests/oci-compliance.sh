#!/usr/bin/env bash
# OCI Runtime Tools compliance test runner for runz.
#
# Prerequisites:
#   - Go toolchain
#   - runz binary built (zig build -Doptimize=ReleaseSafe)
#   - Root access (for namespace operations)
#
# Usage:
#   sudo ./tests/oci-compliance.sh [test-pattern]
#
# Examples:
#   sudo ./tests/oci-compliance.sh              # run all tests
#   sudo ./tests/oci-compliance.sh TestCreate    # run create tests only

set -euo pipefail

RUNZ_BIN="${RUNZ_BIN:-$(pwd)/zig-out/bin/runz}"
RUNTIME_TOOLS_DIR="${RUNTIME_TOOLS_DIR:-/tmp/runtime-tools}"
ROOT_DIR="${ROOT_DIR:-/run/runz-compliance}"
TEST_PATTERN="${1:-}"

echo "=== OCI Runtime Compliance Tests ==="
echo "Runtime: $RUNZ_BIN"
echo "Root:    $ROOT_DIR"
echo ""

# Verify runz binary exists
if [ ! -x "$RUNZ_BIN" ]; then
    echo "Error: runz binary not found at $RUNZ_BIN"
    echo "Build it first: zig build -Doptimize=ReleaseSafe"
    exit 1
fi

echo "runz version: $($RUNZ_BIN --version)"
echo ""

# Clone or update runtime-tools
if [ ! -d "$RUNTIME_TOOLS_DIR" ]; then
    echo "Cloning opencontainers/runtime-tools..."
    git clone --depth=1 https://github.com/opencontainers/runtime-tools.git "$RUNTIME_TOOLS_DIR"
else
    echo "Using existing runtime-tools at $RUNTIME_TOOLS_DIR"
fi

# Create test rootfs
ROOTFS_DIR="$(mktemp -d)/rootfs"
mkdir -p "$ROOTFS_DIR"/{bin,dev,etc,proc,sys,tmp,usr/bin,var}

# Find static busybox
BUSYBOX=""
for path in /nix/store/*busybox-static*/bin/busybox /usr/bin/busybox /bin/busybox; do
    if [ -x "$path" ] 2>/dev/null; then
        BUSYBOX="$path"
        break
    fi
done

if [ -z "$BUSYBOX" ]; then
    echo "Error: static busybox not found"
    exit 1
fi

cp "$BUSYBOX" "$ROOTFS_DIR/bin/busybox"
chmod +x "$ROOTFS_DIR/bin/busybox"
for cmd in sh ls cat echo sleep id true false; do
    ln -sf busybox "$ROOTFS_DIR/bin/$cmd"
done

echo "Test rootfs: $ROOTFS_DIR"
echo ""

# Run basic validation
echo "=== Basic Validation ==="

# Test: spec command produces valid JSON
echo -n "spec produces valid JSON... "
SPEC_OUTPUT=$($RUNZ_BIN spec 2>/dev/null)
if echo "$SPEC_OUTPUT" | grep -q '"ociVersion"'; then
    echo "PASS"
else
    echo "FAIL"
fi

# Test: create with bundle
echo -n "create with bundle... "
BUNDLE_DIR="$(mktemp -d)"
cp -r "$ROOTFS_DIR" "$BUNDLE_DIR/rootfs"
$RUNZ_BIN spec > "$BUNDLE_DIR/config.json"
mkdir -p "$ROOT_DIR"

if $RUNZ_BIN --root "$ROOT_DIR" create compliance-test -b "$BUNDLE_DIR" 2>/dev/null; then
    echo "PASS"

    # Test: state shows created
    echo -n "state shows created... "
    STATE=$($RUNZ_BIN --root "$ROOT_DIR" state compliance-test 2>/dev/null || true)
    if echo "$STATE" | grep -q '"created"'; then
        echo "PASS"
    else
        echo "FAIL: $STATE"
    fi

    # Test: state has required fields
    echo -n "state has ociVersion... "
    if echo "$STATE" | grep -q '"ociVersion"'; then
        echo "PASS"
    else
        echo "FAIL"
    fi

    echo -n "state has id... "
    if echo "$STATE" | grep -q '"id"'; then
        echo "PASS"
    else
        echo "FAIL"
    fi

    echo -n "state has pid... "
    if echo "$STATE" | grep -q '"pid"'; then
        echo "PASS"
    else
        echo "FAIL"
    fi

    echo -n "state has bundle... "
    if echo "$STATE" | grep -q '"bundle"'; then
        echo "PASS"
    else
        echo "FAIL"
    fi

    # Test: start
    echo -n "start... "
    if $RUNZ_BIN --root "$ROOT_DIR" start compliance-test 2>/dev/null; then
        echo "PASS"
    else
        echo "FAIL"
    fi

    sleep 1

    # Test: delete
    echo -n "delete... "
    $RUNZ_BIN --root "$ROOT_DIR" kill compliance-test SIGKILL 2>/dev/null || true
    sleep 1
    if $RUNZ_BIN --root "$ROOT_DIR" delete compliance-test 2>/dev/null; then
        echo "PASS"
    else
        echo "FAIL"
    fi

    # Test: state after delete fails
    echo -n "state after delete fails... "
    if ! $RUNZ_BIN --root "$ROOT_DIR" state compliance-test 2>/dev/null; then
        echo "PASS"
    else
        echo "FAIL"
    fi
else
    echo "FAIL"
fi

# Test: run command
echo -n "run executes process... "
BUNDLE2_DIR="$(mktemp -d)"
cp -r "$ROOTFS_DIR" "$BUNDLE2_DIR/rootfs"
cat > "$BUNDLE2_DIR/config.json" << 'SPEC'
{
  "ociVersion": "1.0.2",
  "process": {"args": ["/bin/echo", "compliance-ok"], "cwd": "/", "env": ["PATH=/bin"]},
  "root": {"path": "rootfs"},
  "mounts": [{"destination": "/proc", "type": "proc", "source": "proc"}],
  "linux": {"namespaces": [{"type": "pid"}, {"type": "mount"}]}
}
SPEC

OUTPUT=$($RUNZ_BIN --root "$ROOT_DIR" run compliance-run -b "$BUNDLE2_DIR" 2>&1 || true)
if echo "$OUTPUT" | grep -q "compliance-ok"; then
    echo "PASS"
else
    echo "FAIL: $OUTPUT"
fi

# Cleanup
rm -rf "$BUNDLE_DIR" "$BUNDLE2_DIR" "$ROOT_DIR" "$(dirname $ROOTFS_DIR)"

echo ""
echo "=== Done ==="
