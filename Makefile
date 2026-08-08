.PHONY: gen build run test test-core test-app format perf clean

gen:
	xcodegen generate

build: gen
	xcodebuild -scheme Ledge -configuration Debug -derivedDataPath .build build

run: build
	open .build/Build/Products/Debug/Ledge.app

test: test-core test-app

test-core:
	swift test --package-path Sources/LedgeCore

test-app: gen
	xcodebuild -scheme Ledge -configuration Debug -derivedDataPath .build -destination 'platform=macOS' test

format:
	swiftformat .

perf:
	scripts/perf-check.sh

clean:
	rm -rf .build Sources/LedgeCore/.build Ledge.xcodeproj
