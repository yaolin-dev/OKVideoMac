# 01 — Components

## FACT

| Component | Exact identity | Role |
|---|---|---|
| juniversalchardet | `com.googlecode.juniversalchardet:juniversalchardet:1.0.3` | Runtime classes exported by `:catvod`; complete JAR converted by D8 into `classes2.dex` |
| FongMi/TV catvod | commit `5fdff00a602dc56e8ba756174daef20edab024f2`, `catvod/src/main` | Copied and locally modified GPL-3.0-only host API in `classes.dex` |
| Local catvod | `OKVideoMac/Helpers/AndroidDexBridge/catvod` | Modified corresponding source and Maven dependency host |
| AndroidDexBridge | `OKVideoMac/Helpers/AndroidDexBridge/app` | Local Android application, HTTP/RPC bridge, and `DexClassLoader` plugin host |
| Release APK | SHA-256 `5a46aec0bcdd9fc446cfeb1e3ddc3d97b1b2de7978ad88b8283d78fec2f20af7` | Embedded in the macOS application and installed into the app-managed Android runtime |
| Maven graph | `app/gradle.lockfile` SHA-256 `8d78cccdaede67020bf060fa8e5488e99c7c7a7fb6c5ccbdd91f7a9bd796e163` | Locked `releaseRuntimeClasspath`; 1.0.3 is direct from project `:catvod` |

Gradle dependency path:

```text
:app releaseRuntimeClasspath
└── project :catvod
    └── com.googlecode.juniversalchardet:juniversalchardet:1.0.3 (api)
```

Runtime/distribution path:

```text
OKVideoMac.app
└── AndroidDexBridge-release.apk
    ├── classes.dex
    │   ├── com.okvideomac.dexbridge.*
    │   └── com.github.catvod.* (copied/modified FongMi GPL-3.0-only)
    ├── classes2.dex
    │   └── org.mozilla.universalchardet.* (all 62 binary classes)
    └── DexClassLoader
        └── configuration-selected external CatVod Spider JAR/DEX
```

## ENGINEERING INFERENCE

The module is not used by the tracked host source or by either currently saved
Java/Dex package's visible DEX, but it remains part of the host runtime class
surface available to dynamically loaded Spiders.

## LEGAL REVIEW REQUIRED

No conclusion is made here about whether multidex placement, the alternative
headers, or the plugin-host relationship is legally compatible.

