#!/bin/bash
set -euo pipefail
video_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$video_dir"
go test -race ./...
mkdir -p ../vendor/scripts/usr/bin
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -trimpath -ldflags='-s -w' -o ../vendor/scripts/usr/bin/qmanager_video_selective .
