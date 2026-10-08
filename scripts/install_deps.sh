#!/usr/bin/env bash
# Install everything this repo needs from apt: Gazebo Harmonic, the build dependencies of
# ArduPilot's Gazebo plugin, and the GStreamer-enabled OpenCV that reads the camera stream.
# Ubuntu 22.04 or 24.04. Safe to re-run. Does NOT install ArduPilot SITL or the NVIDIA driver.
#
#   bash scripts/install_deps.sh
set -eu

. /etc/os-release
case "${VERSION_CODENAME:-}" in
  jammy|noble) ;;
  *) echo "This script supports Ubuntu 22.04 (jammy) and 24.04 (noble); you have ${PRETTY_NAME:-unknown}."
     echo "Install Gazebo Harmonic by hand: https://gazebosim.org/docs/harmonic/install"
     exit 1 ;;
esac

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

echo ">> base tools"
$SUDO apt-get update
$SUDO apt-get install -y curl lsb-release gnupg git cmake build-essential python3-venv python3-pip

# Gazebo's own apt repo, exactly as https://gazebosim.org/docs/harmonic/install_ubuntu sets it up.
KEY=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg
LIST=/etc/apt/sources.list.d/gazebo-stable.list
if [ ! -f "$LIST" ]; then
  echo ">> adding the Gazebo apt repo"
  $SUDO curl -fsSL https://packages.osrfoundation.org/gazebo.gpg --output "$KEY"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=$KEY] https://packages.osrfoundation.org/gazebo/ubuntu-stable $VERSION_CODENAME main" \
    | $SUDO tee "$LIST" >/dev/null
  $SUDO apt-get update
fi

echo ">> Gazebo Harmonic, plugin build deps, camera stream deps"
$SUDO apt-get install -y gz-harmonic \
  libgz-sim8-dev rapidjson-dev libopencv-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
  gstreamer1.0-libav gstreamer1.0-gl gstreamer1.0-tools \
  python3-opencv

echo
echo "done: $(gz sim --version 2>/dev/null | head -1)"
command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1 \
  || echo "note: no working NVIDIA driver found; the camera renders in software, so the sim runs slow."
echo "Next: bash scripts/setup_plugin.sh"
