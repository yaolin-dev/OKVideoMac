# Android Charset Resolution Map

Audit date: 2026-08-13

Scope: tracked AndroidDexBridge and copied local catvod Java source at baseline
`20a7acaaff1854aa686b6cdfc76ca254651fa5dd`. Swift/macOS text decoding is a
separate runtime and is not a consumer of the Android Maven dependency.

## Byte-to-String Census

There are nine production byte-to-String call sites in the Android
compatibility source.

| # | Location | Data | Current charset source | Failure behavior | Detector needed? |
|---:|---|---|---|---|---|
| 1 | `Path.read(File)` | local file | fixed `UTF-8` | returns empty string | no |
| 2 | `Path.read(InputStream)` | asset/local stream | fixed `UTF-8` | returns empty string | no |
| 3 | `Shell.exec` | subprocess stdout | implicit platform default; Android default is UTF-8 | exception returns empty string | no heuristic, but should be made explicit in a future cleanup |
| 4 | `OkHttp.string(url)` | HTTP response | OkHttp `ResponseBody.string()`: response `Content-Type` charset, otherwise UTF-8 | exception returns empty string | no |
| 5 | `OkHttp.string(url, headers)` | HTTP response | same as #4 | exception returns empty string | no |
| 6 | `BridgeServer /v1/ui/submit` | JSON RPC body | protocol-fixed `UTF-8` | request fails | no |
| 7 | `BridgeServer /v1/auth/push` | JSON RPC body | `application/json`, decoded as fixed `UTF-8` | request fails | no |
| 8 | `BridgeServer /v1/invoke` | JSON RPC body | protocol-fixed `UTF-8` | request fails | no |
| 9 | `BridgeServer.readLine` | HTTP request line/headers | protocol-fixed `US-ASCII` | request fails | no |

Six sites use an explicit charset in the call itself (five UTF-8, one ASCII),
two use HTTP metadata with deterministic UTF-8 fallback, and one implicitly
uses Android's UTF-8 platform default. None invokes heuristic detection.

Binary proxy bodies, downloaded Spider JARs, images, encrypted payloads, and
other pass-through streams remain bytes and are not decoded by the bridge.
JSON produced by a Spider is already a Java `String` at the bridge boundary.

## Current Corpus

The legally accessible current text cache contained 263 candidate files. One
file with a `.json` cache suffix was actually a JPEG by magic bytes and was
excluded from text statistics. All 262 actual JSON/JavaScript/dynamic-result
text artifacts passed strict UTF-8 validation.

| Resolution in current retained byte corpus | Count | Percent |
|---|---:|---:|
| explicit metadata retained with bytes | 0 | 0.0% |
| strict UTF-8 | 262 | 100.0% |
| heuristic detector required | 0 | 0.0% |

HTTP headers were not retained alongside these cache files, so the first row
must not be read as evidence that upstream responses lacked metadata. It only
states what could be reproduced from saved bytes.

The standalone resolver prototype used seven project-shaped fixtures (RPC
JSON, HTTP UTF-8, HTTP GB18030, XML declaration, HTML meta, UTF-8 BOM, and M3U
UTF-8). Six of seven (85.7%) resolved before UTF-8 validation, one (14.3%)
resolved as strict UTF-8, and zero required a heuristic.

## Proposed `TextEncodingResolver`

The prototype is intentionally not connected to production. Its interface
should accept bytes plus optional declared/HTTP metadata and return either a
decoded value with provenance or an explicit failure:

```text
TextEncodingResolver.resolve(bytes, suppliedCharset, contentType, mediaKind)
    -> ResolvedText(text, charset, resolutionStage, confidence?)
    -> ResolutionFailure(reason, attemptedStages)
```

Resolution order:

1. BOM;
2. explicitly supplied charset;
3. HTTP `Content-Type` charset;
4. XML encoding declaration;
5. HTML meta charset;
6. strict UTF-8 validation;
7. optional `EncodingDetector` heuristic fallback;
8. deterministic media-specific fallback or a surfaced failure.

Business code should depend only on `TextEncodingResolver` and an optional
`EncodingDetector` protocol. It should not name `UniversalDetector` or
`com.ibm.icu.text.CharsetDetector`. System-default decoding and silent
replacement are not acceptable final fallbacks.

## Actual Need

The original FongMi detector path handled local non-UTF-8 subtitles, but that
path was removed upstream in 2024. No current tracked Android call site needs a
heuristic detector, and no saved current text byte artifact required one.

This supports a no-detector application architecture for tracked code. It does
not prove that protected/external Spider byte-processing code has no detector
dependency, because that code runs inside the Spider rather than through the
bridge's nine conversions.
