import com.ibm.icu.text.CharsetDetector;
import com.ibm.icu.text.CharsetMatch;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.Charset;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import org.mozilla.universalchardet.UniversalDetector;

/**
 * Standalone audit harness. It is not linked into AndroidDexBridge.
 *
 * It compares the exact distributed juniversalchardet 1.0.3 artifact with the
 * exact ICU4J candidate and exercises the metadata-first resolver ordering
 * proposed by the dependency-elimination audit.
 */
public final class CharsetDetectorComparison {
    private record Fixture(String name, String expected, byte[] bytes) {}

    private static final String ZH = "中文字符编码检测，兼容旧网页与字幕。".repeat(48);
    private static final String ZH_TW = "繁體中文字符編碼偵測，兼容舊網頁與字幕。".repeat(48);
    private static final String JA = "日本語の文字コード検出と字幕の互換性。".repeat(48);
    private static final String KO = "한국어 문자 인코딩 감지와 자막 호환성.".repeat(48);
    private static final String LATIN = "Crème brûlée déjà vu, façade et piñata. ".repeat(48);

    public static void main(String[] args) throws Exception {
        List<Fixture> fixtures = fixtures();
        if (args.length == 1 && args[0].equals("--benchmark-legacy")) {
            benchmark("juniversalchardet", fixtures, true);
            return;
        }
        if (args.length == 1 && args[0].equals("--benchmark-icu")) {
            benchmark("icu4j", fixtures, false);
            return;
        }
        System.out.println("fixture\texpected\tjuniversalchardet\ticu4j\ticuConfidence");
        for (Fixture fixture : fixtures) {
            UniversalDetector legacy = new UniversalDetector(null);
            legacy.handleData(fixture.bytes(), 0, fixture.bytes().length);
            legacy.dataEnd();

            CharsetDetector candidate = new CharsetDetector();
            candidate.setText(fixture.bytes());
            CharsetMatch match = candidate.detect();
            System.out.printf(
                    "%s\t%s\t%s\t%s\t%s%n",
                    fixture.name(),
                    fixture.expected(),
                    value(legacy.getDetectedCharset()),
                    match == null ? "NULL" : match.getName(),
                    match == null ? "N/A" : Integer.toString(match.getConfidence())
            );
        }

        benchmark("juniversalchardet", fixtures, true);
        benchmark("icu4j", fixtures, false);
        resolverPrototype();
    }

    private static List<Fixture> fixtures() throws Exception {
        List<Fixture> result = new ArrayList<>();
        result.add(new Fixture("utf8", "UTF-8", ZH.getBytes(StandardCharsets.UTF_8)));
        result.add(new Fixture("utf8-bom", "UTF-8", withBom(
                new byte[] {(byte) 0xef, (byte) 0xbb, (byte) 0xbf},
                ZH.getBytes(StandardCharsets.UTF_8))));
        result.add(new Fixture("utf16le-bom", "UTF-16LE", withBom(
                new byte[] {(byte) 0xff, (byte) 0xfe}, ZH.getBytes(StandardCharsets.UTF_16LE))));
        result.add(new Fixture("utf16be-bom", "UTF-16BE", withBom(
                new byte[] {(byte) 0xfe, (byte) 0xff}, ZH.getBytes(StandardCharsets.UTF_16BE))));
        result.add(new Fixture("gb18030", "GB18030", ZH.getBytes(Charset.forName("GB18030"))));
        result.add(new Fixture("big5", "Big5", ZH_TW.getBytes(Charset.forName("Big5"))));
        result.add(new Fixture("shift-jis", "Shift_JIS", JA.getBytes(Charset.forName("Shift_JIS"))));
        result.add(new Fixture("euc-jp", "EUC-JP", JA.getBytes(Charset.forName("EUC-JP"))));
        result.add(new Fixture("euc-kr", "EUC-KR", KO.getBytes(Charset.forName("EUC-KR"))));
        result.add(new Fixture("iso-8859-1", "ISO-8859-1", LATIN.getBytes(StandardCharsets.ISO_8859_1)));
        result.add(new Fixture("ascii-only", "ASCII/UTF-8", "plain ascii only".getBytes(StandardCharsets.US_ASCII)));
        result.add(new Fixture("short-gb18030", "GB18030", "中文".getBytes(Charset.forName("GB18030"))));
        result.add(new Fixture("mixed-utf8", "UTF-8", (ZH + JA + KO + LATIN).getBytes(StandardCharsets.UTF_8)));
        result.add(new Fixture("malformed", "INVALID", new byte[] {(byte) 0xc3, 0x28, (byte) 0xff, 0x00}));
        return result;
    }

    private static void benchmark(String name, List<Fixture> fixtures, boolean legacy) {
        int rounds = 2_000;
        long started = System.nanoTime();
        int checksum = 0;
        for (int round = 0; round < rounds; round++) {
            for (Fixture fixture : fixtures) {
                if (legacy) {
                    UniversalDetector detector = new UniversalDetector(null);
                    detector.handleData(fixture.bytes(), 0, fixture.bytes().length);
                    detector.dataEnd();
                    if (detector.getDetectedCharset() != null) checksum++;
                } else {
                    CharsetDetector detector = new CharsetDetector();
                    detector.setText(fixture.bytes());
                    if (detector.detect() != null) checksum++;
                }
            }
        }
        long elapsed = System.nanoTime() - started;
        double micros = elapsed / 1_000.0 / (rounds * fixtures.size());
        System.out.printf("benchmark\t%s\t%.3f us/detection\tchecksum=%d%n", name, micros, checksum);
    }

    private static void resolverPrototype() throws Exception {
        record Case(String name, byte[] bytes, String explicit, String contentType) {}
        List<Case> cases = List.of(
                new Case("rpc-json", "{\"ok\":true}".getBytes(StandardCharsets.UTF_8), "UTF-8", null),
                new Case("http-gb18030", ZH.getBytes(Charset.forName("GB18030")), null,
                        "text/html; charset=GB18030"),
                new Case("http-utf8", ZH.getBytes(StandardCharsets.UTF_8), null,
                        "application/json; charset=UTF-8"),
                new Case("xml-declaration",
                        ("<?xml version=\"1.0\" encoding=\"GB18030\"?>" + ZH)
                                .getBytes(Charset.forName("GB18030")), null, null),
                new Case("html-meta",
                        ("<meta charset=\"Big5\">" + ZH_TW).getBytes(Charset.forName("Big5")),
                        null, null),
                new Case("utf8-bom", withBom(new byte[] {(byte) 0xef, (byte) 0xbb, (byte) 0xbf},
                        ZH.getBytes(StandardCharsets.UTF_8)), null, null),
                new Case("playlist-utf8", ("#EXTM3U\n#EXTINF:-1," + ZH)
                        .getBytes(StandardCharsets.UTF_8), null, null)
        );
        int metadata = 0;
        int utf8 = 0;
        int heuristic = 0;
        for (Case item : cases) {
            String stage = resolutionStage(item.bytes(), item.explicit(), item.contentType());
            if (stage.equals("STRICT_UTF8")) utf8++;
            else if (stage.equals("HEURISTIC")) heuristic++;
            else metadata++;
            System.out.printf("resolver\t%s\t%s%n", item.name(), stage);
        }
        System.out.printf("resolver-summary\ttotal=%d\tmetadata=%d\tutf8=%d\theuristic=%d%n",
                cases.size(), metadata, utf8, heuristic);
    }

    private static String resolutionStage(byte[] data, String explicit, String contentType) {
        if (startsWith(data, new byte[] {(byte) 0xef, (byte) 0xbb, (byte) 0xbf})
                || startsWith(data, new byte[] {(byte) 0xff, (byte) 0xfe})
                || startsWith(data, new byte[] {(byte) 0xfe, (byte) 0xff})) return "BOM";
        if (explicit != null) return "EXPLICIT";
        if (contentType != null && contentType.toLowerCase().contains("charset=")) {
            return "HTTP_CONTENT_TYPE";
        }
        String prefix = new String(data, 0, Math.min(data.length, 512), StandardCharsets.ISO_8859_1)
                .toLowerCase();
        if (prefix.contains("<?xml") && prefix.contains("encoding=")) return "XML_DECLARATION";
        if (prefix.contains("<meta") && prefix.contains("charset=")) return "HTML_META";
        if (isStrictUtf8(data)) return "STRICT_UTF8";
        return "HEURISTIC";
    }

    private static boolean isStrictUtf8(byte[] data) {
        try {
            StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(data));
            return true;
        } catch (CharacterCodingException error) {
            return false;
        }
    }

    private static boolean startsWith(byte[] value, byte[] prefix) {
        if (value.length < prefix.length) return false;
        for (int i = 0; i < prefix.length; i++) if (value[i] != prefix[i]) return false;
        return true;
    }

    private static byte[] withBom(byte[] bom, byte[] data) {
        byte[] result = new byte[bom.length + data.length];
        System.arraycopy(bom, 0, result, 0, bom.length);
        System.arraycopy(data, 0, result, bom.length, data.length);
        return result;
    }

    private static String value(String input) {
        return input == null ? "NULL" : input;
    }
}
