# 05 — Distribution Model

## FACT

OKVideoMac distributes a macOS `.app`. The bundle contains
`Contents/Resources/AndroidDexBridge-release.apk` rather than a standalone
Maven JAR. When a Java/Dex site is selected, the macOS application starts or
connects to its managed Android runtime, installs/updates the APK, and invokes
the bridge over a local forwarded connection.

The APK then downloads the configuration-selected external CatVod Spider JAR
over HTTP/HTTPS, verifies an optional/pinned MD5 supplied by the configuration,
and loads it through `DexClassLoader`. The external Spider is not embedded in
the macOS Release bundle. The APK's class loader is the parent and supplies the
local catvod API and all packaged Maven runtime classes.

The distributed Release bundle contains legal notices, SBOMs, source mapping,
source-release index/materials, Gradle locks, and exact juniversalchardet source
evidence. Users interact with the Android code indirectly through the macOS
application; the APK is nevertheless a byte-for-byte distributed bundle
resource.

## ENGINEERING INFERENCE

Removing a host runtime class can affect future or protected external Spiders
without requiring any change to tracked OKVideoMac/FongMi source. Current
configuration scans cannot close that open-ended compatibility surface.

## LEGAL REVIEW REQUIRED

Counsel should assess whether embedding the APK inside the macOS app, installing
it only into an app-managed Android runtime, and dynamically downloading Spider
packages changes notice, source-offer, or combination analysis.

