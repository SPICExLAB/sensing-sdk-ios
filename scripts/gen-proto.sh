#!/usr/bin/env bash
# Regenerate Sources/SensingProto from proto/, which is a copy of the Android SDK's envelope.proto.
# protoc-gen-swift is built from the resolved swift-protobuf checkout, so its version always matches the runtime.
#   scripts/gen-proto.sh
set -euo pipefail
cd "$(dirname "$0")/.."
swift package resolve >/dev/null
swift build --package-path .build/checkouts/swift-protobuf -c release --product protoc-gen-swift >/dev/null
PLUGIN=$(swift build --package-path .build/checkouts/swift-protobuf -c release --show-bin-path)/protoc-gen-swift
rm -f Sources/SensingProto/*.pb.swift
protoc -I proto --plugin=protoc-gen-swift="$PLUGIN" --swift_out=Sources/SensingProto \
  --swift_opt=Visibility=Public --swift_opt=FileNaming=DropPath proto/sensorlog/v1/*.proto
SDK_REF=$(cat proto/SENSING_SDK_REF)
echo "sensing-sdk $SDK_REF $(protoc --version) protoc-gen-swift $("$PLUGIN" --version 2>&1 | tail -1)" > Sources/SensingProto/PROTO_VERSION
echo "generated from $(cat Sources/SensingProto/PROTO_VERSION)"
