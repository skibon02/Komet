{
  description = "Komet — Flutter Android build environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs {
          inherit system overlays;
          config.allowUnfree = true;
          config.android_sdk.accept_license = true;
        };

        androidEnv = pkgs.androidenv.override { licenseAccepted = true; };
        androidComposition = androidEnv.composeAndroidPackages {
          platformVersions = [ "36" ];
          buildToolsVersions = [ "36.0.0" ];
          includeNDK = true;
          ndkVersions = [ "29.0.14206865" ];
          includeCmake = true;
          cmakeVersions = [ "4.1.2" ];
          includeEmulator = false;
          includeSystemImages = false;
          abiVersions = [ "arm64-v8a" "armeabi-v7a" "x86_64" ];
        };
        androidSdk = androidComposition.androidsdk;
        ndkVersion = "29.0.14206865";

        # Cargokit (used by the kolibri/komet_crypto plugins) requires a real
        # `rustup` and installs the `stable` toolchain + Android targets into a
        # writable RUSTUP_HOME on first build. rust-overlay's toolchain does not
        # provide the `rustup` binary cargokit shells out to.
        rustTargets = [
          "aarch64-linux-android"
          "armv7-linux-androideabi"
          "x86_64-linux-android"
        ];
        rustToolchain = pkgs.rust-bin.stable.latest.default.override {
          targets = rustTargets;
        };

        # NDK + toolchain env vars consumed by the Rust/CMake Android build.
        androidNdkRoot = "${androidSdk}/libexec/android-sdk/ndk/${ndkVersion}";

        commonEnv = {
          ANDROID_HOME = "${androidSdk}/libexec/android-sdk";
          ANDROID_SDK_ROOT = "${androidSdk}/libexec/android-sdk";
          ANDROID_NDK_ROOT = androidNdkRoot;
          ANDROID_NDK_HOME = androidNdkRoot;
          KOMET_NDK_VERSION = ndkVersion;
          KOMET_BUILD_TOOLS_VERSION = "36.0.0";
          KOMET_COMPILE_SDK = "36";
          KOMET_CMAKE_VERSION = "4.1.2";
          JAVA_HOME = "${pkgs.jdk17}/lib/openjdk";
        };

        buildInputs = [
          pkgs.flutter
          pkgs.jdk17
          rustToolchain
          pkgs.rustup
          pkgs.cargo
          pkgs.cmake
          pkgs.ninja
          pkgs.pkg-config
          pkgs.git
          pkgs.unzip
          pkgs.which
          androidSdk
        ];

        # The build needs network access (pub.dev + Gradle/Maven) and a
        # writable HOME for the Flutter/Gradle caches, so it cannot run inside
        # the Nix sandbox. The devShell provides the full toolchain; the actual
        # build is a helper script that runs in the user's environment.
        buildApk = pkgs.writeShellScriptBin "build-apk" ''
          set -euo pipefail
          export HOME="''${HOME:-$PWD}"
          export GRADLE_USER_HOME="''${GRADLE_USER_HOME:-$PWD/.gradle}"
          export PUB_CACHE="''${PUB_CACHE:-$PWD/.pub-cache}"
          # Cargokit installs the Rust stable toolchain + Android targets via
          # rustup into these writable dirs on first build.
          export RUSTUP_HOME="''${RUSTUP_HOME:-$PWD/.rustup}"
          export CARGO_HOME="''${CARGO_HOME:-$PWD/.cargo}"
          mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"
          # CMake 4.x dropped compatibility with cmake_minimum_required < 3.5,
          # which some plugins (ogg_opus_player) still declare. This restores it.
          export CMAKE_POLICY_VERSION_MINIMUM=3.5
          # Force every Android subproject to use the tool versions from the
          # Nix androidenv instead of AGP's defaults (which would be
          # auto-installed into the read-only store and fail).
          mkdir -p "$GRADLE_USER_HOME/init.d"
          cp "$PWD/scripts/nix-android.gradle" "$GRADLE_USER_HOME/init.d/nix-android.gradle"
          flutter config --no-analytics >/dev/null 2>&1 || true
          flutter config --android-sdk "$ANDROID_HOME" >/dev/null 2>&1 || true
          git submodule update --init --recursive
          flutter pub get
          flutter build apk --release --flavor komet \
            --dart-define=KOMET_AUTO_UPDATE=false "$@"
          echo ""
          echo "APK: build/app/outputs/flutter-apk/app-komet-release.apk"
        '';
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = buildInputs ++ [ buildApk ];

          inherit (commonEnv) ANDROID_HOME ANDROID_SDK_ROOT ANDROID_NDK_ROOT
            ANDROID_NDK_HOME KOMET_NDK_VERSION KOMET_BUILD_TOOLS_VERSION
            KOMET_COMPILE_SDK KOMET_CMAKE_VERSION JAVA_HOME;

          shellHook = ''
            export GRADLE_USER_HOME="$PWD/.gradle"
            export PUB_CACHE="$PWD/.pub-cache"
            echo "Komet dev shell"
            echo "  flutter : $(flutter --version 2>/dev/null | head -1)"
            echo "  java    : $(java -version 2>/dev/null | head -1)"
            echo "  ndk     : $KOMET_NDK_VERSION"
            echo ""
            echo "Build APK (komet flavor, auto-update disabled):"
            echo "  build-apk"
          '';
        };
      });
}
