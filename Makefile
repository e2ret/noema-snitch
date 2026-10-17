APP = build/Noema Snitch.app

.PHONY: build run run-ru run-en clean

build:
	./scripts/build-app.sh

run: build
	open "$(APP)"

# Launch with a forced UI language to check translations.
run-ru: build
	"$(APP)/Contents/MacOS/NoemaSnitch" -AppleLanguages '(ru)' &

run-en: build
	"$(APP)/Contents/MacOS/NoemaSnitch" -AppleLanguages '(en)' &

clean:
	rm -rf .build build
