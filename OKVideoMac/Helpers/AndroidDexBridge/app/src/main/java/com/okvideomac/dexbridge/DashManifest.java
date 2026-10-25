package com.okvideomac.dexbridge;

import java.io.*;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.regex.*;
import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.transform.*;
import javax.xml.transform.dom.DOMSource;
import javax.xml.transform.stream.StreamResult;
import org.w3c.dom.*;
import org.xml.sax.SAXException;

/** Request-scoped MPD references. Credentials remain on the provider VM. */
final class DashManifest {
    static final int MAX_BYTES = 2 * 1024 * 1024;
    interface Registrar { String register(List<String> upstreams) throws IOException; }

    static boolean isDASH(String mime) {
        return mime != null && mime.toLowerCase(Locale.ROOT).split(";", 2)[0].trim().equals("application/dash+xml");
    }

    /** Some Bili providers omit browser headers from their generated MPD.
     * Used only after a DASH child returns 403, never for ordinary media.
     * Explicit provider values are authoritative; no credentials are added. */
    static Map<String, String> forbiddenCDNHeaders(String upstream,
            Map<String, String> forwarded, Map<String, String> provider) throws IOException {
        String host = new URL(upstream).getHost().toLowerCase(Locale.ROOT);
        boolean known = false;
        for (String domain : new String[]{"bilivideo.com", "bilivideo.cn", "mountaintoys.cn"})
            if (host.equals(domain) || host.endsWith("." + domain)) known = true;
        if (!known) return null;
        Map<String, String> retry = new LinkedHashMap<>(forwarded);
        for (String name : new String[]{"User-Agent", "Referer"}) {
            boolean explicit = false;
            for (Map.Entry<String, String> entry : provider.entrySet())
                if (name.equalsIgnoreCase(entry.getKey()) && entry.getValue() != null
                        && !entry.getValue().trim().isEmpty()) explicit = true;
            if (explicit) continue;
            retry.keySet().removeIf(key -> name.equalsIgnoreCase(key));
            retry.put(name, name.equals("Referer") ? "https://www.bilibili.com/" : "Mozilla/5.0");
        }
        return retry.equals(forwarded) ? null : retry;
    }

    static byte[] rewrite(InputStream input, String base, Registrar registrar) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        try (InputStream body = input) {
            int n;
            while ((n = body.read(buffer)) != -1) {
                if (bytes.size() + n > MAX_BYTES) throw new IOException("DASH manifest exceeds limit");
                bytes.write(buffer, 0, n);
            }
        }
        try {
            // MPDs do not need DTDs or entities. Reject them before parsing,
            // including on Android parsers which lack the Xerces feature API.
            String xml = bytes.toString("UTF-8");
            String upper = xml.toUpperCase(Locale.ROOT);
            if (upper.contains("<!DOCTYPE") || upper.contains("<!ENTITY") || xml.indexOf('\0') >= 0)
                throw new IOException("DASH external declarations are unsupported");
            DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
            factory.setNamespaceAware(true);
            factory.setExpandEntityReferences(false);
            javax.xml.parsers.DocumentBuilder builder = factory.newDocumentBuilder();
            builder.setEntityResolver((publicID, systemID) -> { throw new SAXException("External entity rejected"); });
            Document document = builder.parse(new ByteArrayInputStream(bytes.toByteArray()));
            if (!"MPD".equals(document.getDocumentElement().getLocalName())) throw new IOException("Invalid MPD root");
            expandInheritedSegments(document);
            rewriteElement(document.getDocumentElement(), Collections.singletonList(base), registrar);
            ByteArrayOutputStream output = new ByteArrayOutputStream();
            Transformer transformer = TransformerFactory.newInstance().newTransformer();
            transformer.setOutputProperty(OutputKeys.ENCODING, "UTF-8");
            transformer.transform(new DOMSource(document), new StreamResult(output));
            return output.toByteArray();
        } catch (IOException e) {
            throw e;
        } catch (Exception e) {
            throw new IOException("Invalid DASH manifest", e);
        }
    }

    private static void expandInheritedSegments(Document document) {
        NodeList representations = document.getElementsByTagNameNS("*", "Representation");
        for (int i = 0; i < representations.getLength(); i++) {
            Element representation = (Element) representations.item(i);
            List<Element> ancestry = new ArrayList<>();
            for (Node n = representation; n instanceof Element; n = n.getParentNode()) ancestry.add(0, (Element) n);
            for (String kind : new String[]{"SegmentTemplate", "SegmentList", "SegmentBase"}) {
                Element merged = null;
                for (Element ancestor : ancestry) {
                    for (Node n = ancestor.getFirstChild(); n != null; n = n.getNextSibling()) {
                        if (!(n instanceof Element) || !kind.equals(n.getLocalName())) continue;
                        Element current = (Element) n;
                        if (merged == null) { merged = (Element) current.cloneNode(true); continue; }
                        NamedNodeMap attrs = current.getAttributes();
                        for (int a = 0; a < attrs.getLength(); a++) {
                            Attr attr = (Attr) attrs.item(a);
                            merged.setAttributeNS(attr.getNamespaceURI(), attr.getName(), attr.getValue());
                        }
                        Set<String> replaced = new HashSet<>();
                        for (Node child = current.getFirstChild(); child != null; child = child.getNextSibling()) {
                            if (!(child instanceof Element)) continue;
                            if (replaced.add(child.getLocalName())) {
                                for (Node old = merged.getFirstChild(), next; old != null; old = next) {
                                    next = old.getNextSibling();
                                    if (child.getLocalName().equals(old.getLocalName())) merged.removeChild(old);
                                }
                            }
                            merged.appendChild(child.cloneNode(true));
                        }
                    }
                }
                if (merged != null) {
                    for (Node n = representation.getFirstChild(), next; n != null; n = next) {
                        next = n.getNextSibling();
                        if (kind.equals(n.getLocalName())) representation.removeChild(n);
                    }
                    representation.appendChild(merged);
                }
            }
        }
        for (String kind : new String[]{"SegmentTemplate", "SegmentList", "SegmentBase"}) {
            NodeList nodes = document.getElementsByTagNameNS("*", kind);
            for (int i = nodes.getLength() - 1; i >= 0; i--) {
                Node node = nodes.item(i);
                if (!"Representation".equals(node.getParentNode().getLocalName())) node.getParentNode().removeChild(node);
            }
        }
    }

    private static String absolute(String base, String reference) throws IOException {
        URL result = new URL(new URL(base), reference.trim());
        if (!(result.getProtocol().equals("http") || result.getProtocol().equals("https"))
                || result.getUserInfo() != null) throw new IOException("Unsupported DASH reference");
        return result.toExternalForm();
    }

    private static List<String> resolve(List<String> bases, String reference) throws IOException {
        List<String> urls = new ArrayList<>();
        for (String base : bases) {
            String url = absolute(base, reference);
            if (!urls.contains(url)) urls.add(url);
        }
        return urls;
    }

    private static void rewriteElement(Element element, List<String> inheritedBases, Registrar registrar) throws IOException {
        List<String> bases = new ArrayList<>();
        List<Node> baseNodes = new ArrayList<>();
        for (Node n = element.getFirstChild(); n != null; n = n.getNextSibling()) {
            if (n instanceof Element && "BaseURL".equals(n.getLocalName())) {
                for (String url : resolve(inheritedBases, n.getTextContent())) {
                    if (!bases.contains(url)) bases.add(url);
                }
                baseNodes.add(n);
            }
        }
        if (bases.isEmpty()) bases = inheritedBases;
        if (bases.size() > 8) throw new IOException("Too many DASH mirrors");
        if (!baseNodes.isEmpty()) {
            baseNodes.get(0).setTextContent(registrar.register(bases));
            for (int i = 1; i < baseNodes.size(); i++) element.removeChild(baseNodes.get(i));
        }
        String kind = element.getLocalName();
        String[] attributes = "SegmentTemplate".equals(kind) ? new String[]{"media", "initialization", "index"}
                : "SegmentURL".equals(kind) ? new String[]{"media", "index"}
                : ("Initialization".equals(kind) || "RepresentationIndex".equals(kind)) ? new String[]{"sourceURL"}
                : new String[0];
        for (String attr : attributes) {
            if (element.hasAttribute(attr) && !element.getAttribute(attr).isEmpty())
                element.setAttribute(attr, registrar.register(resolve(bases, element.getAttribute(attr))));
        }
        for (Node n = element.getFirstChild(); n != null; n = n.getNextSibling()) {
            if (n instanceof Element && !"BaseURL".equals(n.getLocalName()))
                rewriteElement((Element) n, bases, registrar);
        }
    }

    static final class Resource {
        private static final Pattern VARIABLE = Pattern.compile("\\$(RepresentationID|Bandwidth|Number|Time)(%0[1-9][0-9]?d)?\\$");
        final List<String> upstreams;
        int preferredIndex;
        final List<String> variables = new ArrayList<>();
        final List<String> kinds = new ArrayList<>();
        Resource(String upstream) { this(Collections.singletonList(upstream)); }
        Resource(List<String> upstreams) {
            this.upstreams = new ArrayList<>(upstreams);
            for (String upstream : upstreams) {
                Matcher matcher = VARIABLE.matcher(upstream);
                while (matcher.find()) {
                    if (!variables.contains(matcher.group())) { variables.add(matcher.group()); kinds.add(matcher.group(1)); }
                }
            }
        }
        String downstream(String path) {
            for (int i = 0; i < variables.size(); i++) path += (i == 0 ? "?" : "&") + "v" + i + "=" + variables.get(i);
            return path;
        }
        String resolve(Map<String, String> query) throws IOException { return resolveAll(query).get(0); }
        synchronized List<String> resolveAll(Map<String, String> query) throws IOException {
            List<String> result = new ArrayList<>();
            for (int i = 0; i < upstreams.size(); i++) result.add(substitute(upstreams.get((preferredIndex + i) % upstreams.size()), query));
            return result;
        }
        synchronized void prefer(String url, Map<String, String> query) throws IOException {
            for (int i = 0; i < upstreams.size(); i++) if (substitute(upstreams.get(i), query).equals(url)) preferredIndex = i;
        }
        private String substitute(String upstream, Map<String, String> query) throws IOException {
            String result = upstream;
            for (int i = 0; i < variables.size(); i++) {
                String value = query.get("v" + i);
                String pattern = kinds.get(i).equals("RepresentationID") ? "[A-Za-z0-9_~-][A-Za-z0-9._~-]{0,159}" : "[0-9]{1,20}";
                if (value == null || !value.matches(pattern) || value.contains(".."))
                    throw new IOException("Invalid DASH template substitution");
                result = result.replace(variables.get(i), value);
            }
            return result.replace("$$", "$");
        }
    }
}
