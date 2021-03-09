#!/bin/sh

#
# Copyright 2019-2021 Signal Messenger, LLC
# SPDX-License-Identifier: AGPL-3.0-only
#

# Specify WebRTC version.  This corresponds to the
# branch or tag of the signalapp/webrtc repository.
WEBRTC_VERSION="4183j"

RINGRTC_MAJOR_VERSION=2
RINGRTC_MINOR_VERSION=9
RINGRTC_REVISION=0

# Specify RingRTC version to publish.
RINGRTC_VERSION="${RINGRTC_MAJOR_VERSION}.${RINGRTC_MINOR_VERSION}.${RINGRTC_REVISION}"

# Release candidate -- for pre-release versions.  Uncomment to use.
# RC_VERSION="alpha"

# Project version is the combination of the two
PROJECT_VERSION="${OVERRIDE_VERSION:-${RINGRTC_VERSION}}${RC_VERSION:+-$RC_VERSION}"
