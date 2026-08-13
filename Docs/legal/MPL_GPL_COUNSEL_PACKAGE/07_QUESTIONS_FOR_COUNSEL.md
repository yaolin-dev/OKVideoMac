# 07 — Questions for Counsel

1. Do the exact 57 MPL-1.1/GPL-2.0-or-later/LGPL-2.1-or-later file headers
   constitute an effective alternative licensing grant for this distribution?
2. How should the headerless `Constants.java` and the artifact POM's MPL-only
   declaration be treated when assessing the complete 1.0.3 component?
3. Does packaging the covered classes and GPL-3.0-only FongMi/catvod classes in
   one APK/application/class-loader graph create a compatibility issue even
   though they are in separate `classes2.dex` and `classes.dex` files and no
   current static reference was found?
4. If there is an issue, would removing or independently replacing
   juniversalchardet be sufficient to resolve this specific combination issue?
5. If the component is retained, which exact source, license, copyright,
   modification, notice, and availability materials must accompany the APK?
6. Is the current AndroidDexBridge/FongMi/catvod corresponding-source model,
   including exact upstream commit, local source, change notice, Gradle build
   files, and lock, sufficient for applicable obligations?
7. Does distribution as a resource embedded in a macOS app and installation
   into an app-managed Android runtime affect the analysis?
8. Is an additional written offer, prominent notice, or source-availability
   notice required in the app UI, bundle, download page, or another channel?
9. Does exposing the APK class loader as parent to dynamically downloaded
   third-party Spider JARs change the combination or distribution analysis?
10. If counsel concludes that the 57 files may be handled under GPL 2.0 or
    later, what license/notice treatment is required for `Constants.java` and
    the component-level Maven metadata?

No answer is implied by the wording of these questions.

