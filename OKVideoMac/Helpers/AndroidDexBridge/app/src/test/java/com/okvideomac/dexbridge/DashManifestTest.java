package com.okvideomac.dexbridge;

import org.junit.Test;
import static org.junit.Assert.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public final class DashManifestTest {
    @Test public void forbiddenCDNRetryIsBoundedAndPreservesProviderHeadersAndRange() throws Exception {
        Map<String,String> original = new LinkedHashMap<>();
        original.put("user-agent","Lavf/61");original.put("Range","bytes=500-999");
        Map<String,String> retry = DashManifest.forbiddenCDNHeaders("https://edge.bilivideo.cn/video.m4s",original,Collections.emptyMap());
        assertEquals("Mozilla/5.0",retry.get("User-Agent"));
        assertEquals("https://www.bilibili.com/",retry.get("Referer"));
        assertEquals("bytes=500-999",retry.get("Range"));
        assertEquals("Lavf/61",original.get("user-agent"));
        assertNull(DashManifest.forbiddenCDNHeaders("https://bilivideo.cn.evil.example/v",original,Collections.emptyMap()));
        assertNull(DashManifest.forbiddenCDNHeaders("https://other.example/v",original,Collections.emptyMap()));
        Map<String,String> explicit = new LinkedHashMap<>();
        explicit.put("user-agent","ProviderUA");explicit.put("referer","https://provider.example/");
        explicit.put("Authorization","private-token");explicit.put("Range","bytes=20-30");
        assertNull(DashManifest.forbiddenCDNHeaders("https://cdn.bilivideo.com/v",explicit,explicit));
        Map<String,String> one = new LinkedHashMap<>();one.put("referer","https://provider.example/");
        retry=DashManifest.forbiddenCDNHeaders("https://edge.mountaintoys.cn/v",one,one);
        assertEquals("https://provider.example/",retry.get("referer"));
        assertEquals("Mozilla/5.0",retry.get("User-Agent"));
        assertFalse(retry.containsKey("Authorization"));
    }
    private String rewrite(String body, List<String> references) throws Exception {
        return new String(DashManifest.rewrite(new ByteArrayInputStream(body.getBytes(StandardCharsets.UTF_8)),
            "https://media.example/final/manifest.mpd", upstream -> {
                references.addAll(upstream); return "/proxy/media/SESSION/dash/" + references.size();
            }), StandardCharsets.UTF_8);
    }
    private String mpd(String content) { return "<MPD xmlns='urn:mpeg:dash:schema:mpd:2011'><Period>" + content + "</Period></MPD>"; }
    @Test public void segmentBasePreservesByteRangesAndScopesBothTracks() throws Exception {
        List<String> refs = new ArrayList<>();
        String result = rewrite(mpd("<AdaptationSet><Representation id='v'><BaseURL>v.mp4?token=SECRET&amp;foo=1</BaseURL><SegmentBase indexRange='801-920'><Initialization range='0-800'/></SegmentBase></Representation><Representation id='a'><BaseURL>https://audio.example/a.mp4</BaseURL><SegmentBase indexRange='701-820'><Initialization range='0-700'/></SegmentBase></Representation></AdaptationSet>"), refs);
        assertEquals(2, refs.size()); assertTrue(refs.get(0).contains("/final/v.mp4?token=SECRET&foo=1"));
        assertFalse(result.contains("SECRET")); assertFalse(result.contains("audio.example"));
        assertTrue(result.contains("indexRange=\"801-920\"")); assertTrue(result.contains("range=\"0-700\""));
    }
    @Test public void inheritedTemplateUsesRepresentationBaseAndRetainsTimeline() throws Exception {
        List<String> refs = new ArrayList<>();
        String result = rewrite(mpd("<AdaptationSet><SegmentTemplate timescale='1000' media='chunk-$RepresentationID$-$Number%05d$.m4s' initialization='init-$RepresentationID$.mp4'><SegmentTimeline><S t='0' d='2000' r='5'/></SegmentTimeline></SegmentTemplate><Representation id='v'><BaseURL>video/</BaseURL></Representation><Representation id='a'><BaseURL>audio/</BaseURL></Representation></AdaptationSet>"), refs);
        assertTrue(refs.contains("https://media.example/final/video/chunk-$RepresentationID$-$Number%05d$.m4s"));
        assertTrue(refs.contains("https://media.example/final/audio/init-$RepresentationID$.mp4"));
        assertTrue(result.contains("SegmentTimeline")); assertTrue(result.contains("timescale=\"1000\""));
    }
    @Test public void segmentListUsesRelativeInitAndMediaAfterRedirect() throws Exception {
        List<String> refs = new ArrayList<>();
        String result = rewrite(mpd("<AdaptationSet><Representation><SegmentList><Initialization sourceURL='../init.mp4' range='0-30'/><SegmentURL media='segment.m4s' mediaRange='20-99'/></SegmentList></Representation></AdaptationSet>"), refs);
        assertEquals(Arrays.asList("https://media.example/init.mp4", "https://media.example/final/segment.m4s"), refs);
        assertTrue(result.contains("mediaRange=\"20-99\""));
    }
    @Test public void templateOnlyAcceptsBoundedMediaSubstitutions() throws Exception {
        DashManifest.Resource r = new DashManifest.Resource("https://media.example/$RepresentationID$/chunk-$Number%05d$-$Time$.m4s?fixed=1");
        assertTrue(r.downstream("/proxy/media/a/dash/b").contains("v1=$Number%05d$"));
        Map<String,String> good = new HashMap<>();good.put("v0","video-1");good.put("v1","00042");good.put("v2","9000");
        assertEquals("https://media.example/video-1/chunk-00042-9000.m4s?fixed=1",r.resolve(good));
        for (String invalid : Arrays.asList("../secret", "https://evil.example", "a?token=1", "..", "")) {
            good.put("v0",invalid);
            try { r.resolve(good); fail("Unsafe substitution"); } catch(IOException expected) {}
        }
    }
    @Test public void mirrorsShareOneCapabilityAndRememberSuccessfulChoice() throws Exception {
        List<String> refs = new ArrayList<>();
        String result = rewrite(mpd("<AdaptationSet><Representation><BaseURL>https://first.example/v.mp4</BaseURL><BaseURL>https://backup.example/v.mp4</BaseURL><SegmentBase indexRange='20-80'/></Representation></AdaptationSet>"),refs);
        assertEquals(2,refs.size());
        assertEquals(1,result.split("<BaseURL>",-1).length-1);
        DashManifest.Resource resource = new DashManifest.Resource(refs);
        resource.prefer(refs.get(1),Collections.emptyMap());
        assertEquals(refs.get(1),resource.resolveAll(Collections.emptyMap()).get(0));
    }
    @Test public void rejectsExternalEntitiesAndOversizedManifests() throws Exception {
        for (String xml : Arrays.asList("<!DOCTYPE MPD [<!ENTITY ex SYSTEM 'file:///etc/passwd'>]>" + mpd("&ex;"),
                new String(new char[DashManifest.MAX_BYTES + 1]).replace('\0','x'))) {
            try { rewrite(xml, new ArrayList<>()); fail("Unsafe or oversized MPD"); } catch(IOException expected) {}
        }
    }
    @Test public void childCapabilityCannotSurviveHeaderRevisionOrMoveToAnotherSession() throws Exception {
        BridgeMediaSessionRegistry.Session a = new BridgeMediaSessionRegistry.Session("A","http://127.0.0.1/proxy",Collections.singletonMap("Referer","https://source.example/"),null);
        BridgeMediaSessionRegistry.Session b = new BridgeMediaSessionRegistry.Session("B","http://127.0.0.1/proxy",Collections.emptyMap(),null);
        String path = a.registerDashResource(Collections.singletonList("https://cdn.example/v.mp4"),a.upstreamFingerprint);
        String child = path.substring(path.lastIndexOf('/')+1);
        assertEquals("https://cdn.example/v.mp4",a.resolveDashResource(child,Collections.emptyMap()).get(0));
        try { b.resolveDashResource(child,Collections.emptyMap());fail(); } catch(IOException expected) {}
        String oldFingerprint=a.upstreamFingerprint;
        a.mergeHeaders(Collections.singletonMap("Referer","https://changed.example/"));
        try { a.resolveDashResource(child,Collections.emptyMap());fail(); } catch(IOException expected) {}
        try { a.registerDashResource(Collections.singletonList("https://cdn.example/v.mp4"),oldFingerprint);fail(); } catch(IOException expected) {}
    }
}
