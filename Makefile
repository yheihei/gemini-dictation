.PHONY: app test run snapshots clean

# Build build/GeminiDictation.app (release, ad hoc signed).
app:
	./scripts/build-app.sh

# Unit tests. No microphone, network, Keychain or permissions are used.
test:
	./scripts/test.sh

# Build and open the menu bar app.
run: app
	open build/GeminiDictation.app

# Render the Settings window and status panel to PNG files in build/ui-snapshots.
snapshots:
	swift run UISnapshots build/ui-snapshots

clean:
	rm -rf .build build
