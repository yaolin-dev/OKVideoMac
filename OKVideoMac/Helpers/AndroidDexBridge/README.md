# OKVideoDexBridge

This optional Android helper executes FongMi Java/Dex spiders that depend on
Android `DexClassLoader` and Android-native libraries. It runs only inside the
project's headless ARM emulator and binds its RPC server to the emulator
loopback interface.

The macOS app connects through an explicit ADB loopback port forward. The
helper is not a general Java or shell execution service.

The `catvod` source directory is copied from the pinned FongMi/TV audit
revision by `Scripts/prepare-android-dex-bridge.sh`; upstream copyright and
GPL-3.0 terms apply.
