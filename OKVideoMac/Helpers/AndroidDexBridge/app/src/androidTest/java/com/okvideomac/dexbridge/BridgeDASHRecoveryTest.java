package com.okvideomac.dexbridge;

import junit.framework.TestCase;
import java.io.*;
import java.net.*;
import java.lang.reflect.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

/** Exercise the production HTTP opener, Range validation, resume stream and
 * downstream chunk framing over real sockets, with a deliberately cut body. */
public final class BridgeDASHRecoveryTest extends TestCase {
    public void testTruncatedHTTPBodyContinuesOneDownstreamResponseAtExactByte() throws Exception {
        final int start=3109, total=200000, cut=12345;
        byte[] content=new byte[total];
        for(int i=0;i<total;i++) content[i]=(byte)(i%251);
        try(ServerSocket upstream=new ServerSocket(0,4,InetAddress.getByName("127.0.0.1"));
            ServerSocket downstream=new ServerSocket(0,4,InetAddress.getByName("127.0.0.1"))) {
            upstream.setSoTimeout(5000); downstream.setSoTimeout(5000);
            FutureTask<List<String>> requests=new FutureTask<>(()->{
                List<String> ranges=new ArrayList<>();
                for(int i=0;i<2;i++) try(Socket socket=upstream.accept()) {
                    socket.setSoTimeout(5000);
                    BufferedReader reader=new BufferedReader(new InputStreamReader(socket.getInputStream(),StandardCharsets.US_ASCII));
                    String line; while((line=reader.readLine())!=null&&!line.isEmpty())
                        if(line.toLowerCase(Locale.ROOT).startsWith("range:")) ranges.add(line.substring(6).trim());
                    int from=i==0?start:start+cut;
                    OutputStream out=socket.getOutputStream();
                    out.write(("HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Range: bytes "+from+"-"+(total-1)+"/"+total
                        +"\r\nContent-Length: "+(total-from)+"\r\nETag: \"fixture-v1\"\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                    out.write(content,from,i==0?cut:total-from);out.flush();
                }
                return ranges;
            });
            new Thread(requests,"dash-upstream-cut").start();
            FutureTask<Void> relay=new FutureTask<>(()->{
                try(Socket client=downstream.accept(); MediaRequestLifetime lifetime=new MediaRequestLifetime(client,client.getInputStream(),false)) {
                    BufferedReader reader=new BufferedReader(new InputStreamReader(client.getInputStream(),StandardCharsets.US_ASCII));
                    String line;while((line=reader.readLine())!=null&&!line.isEmpty()) { }
                    URI uri=URI.create("http://127.0.0.1:"+upstream.getLocalPort()+"/video");
                    MediaRequestNetworkPolicy policy=MediaRequestNetworkPolicy.direct();
                    BridgeMediaSessionRegistry.Session session=BridgeMediaSessionRegistry.remoteWithNetworkPolicy(uri.toString(),null,policy);
                    Method execute=BridgeServer.class.getDeclaredMethod("executeSessionMedia",URI.class,Map.class,boolean.class,MediaRequestNetworkPolicy.class,MediaRequestLifetime.class,boolean.class);
                    execute.setAccessible(true);
                    Map<String,String> headers=new LinkedHashMap<>(); headers.put("Range","bytes="+start+"-");
                    Object response=execute.invoke(null,uri,headers,false,policy,lifetime,true);
                    Method write=BridgeServer.class.getDeclaredMethod("writeResumableDASH",BufferedOutputStream.class,response.getClass(),BridgeMediaSessionRegistry.Session.class,String.class,List.class,String.class,MediaRequestNetworkPolicy.class,MediaRequestLifetime.class,String.class);
                    write.setAccessible(true);
                    write.invoke(null,new BufferedOutputStream(client.getOutputStream()),response,session,session.upstreamFingerprint,
                        Collections.singletonList(uri.toString()),"bytes="+start+"-",policy,lifetime,"fixture");
                }
                return null;
            });
            new Thread(relay,"dash-real-relay").start();
            HttpURLConnection client=(HttpURLConnection)new URL("http://127.0.0.1:"+downstream.getLocalPort()+"/video").openConnection();
            client.setReadTimeout(10000);client.setConnectTimeout(3000);
            try {
                assertEquals(206,client.getResponseCode());
                assertEquals("bytes "+start+"-"+(total-1)+"/"+total,client.getHeaderField("Content-Range"));
                try(InputStream in=client.getInputStream()) {
                    int position=start,count; byte[] buffer=new byte[8192];
                    while((count=in.read(buffer))>=0) for(int i=0;i<count;i++) assertEquals(content[position++],buffer[i]);
                    assertEquals(total,position);
                }
            } finally { client.disconnect(); }
            relay.get(5,TimeUnit.SECONDS);
            assertEquals(Arrays.asList("bytes="+start+"-","bytes="+(start+cut)+"-"+(total-1)),requests.get(5,TimeUnit.SECONDS));
        }
    }
}
