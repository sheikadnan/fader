.PHONY: build test app run probe clean

build:
	swift build

test:
	./Scripts/test.sh

app:
	./Scripts/build-app.sh

run: app
	open Fader.app

probe:
	swift run fader-probe

clean:
	swift package clean
