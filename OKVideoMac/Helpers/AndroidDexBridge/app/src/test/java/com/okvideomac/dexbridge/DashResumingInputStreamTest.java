package com.okvideomac.dexbridge;

import org.junit.Test;
import java.io.*;
import java.util.concurrent.atomic.*;
import static org.junit.Assert.*;

public class DashResumingInputStreamTest {
    private InputStream bytes(long start,long end) {
        return new InputStream() {
            long pos=start;
            public int read() { return pos>end ? -1 : (int)(pos++%251); }
            public int read(byte[] b,int off,int len) {
                if(pos>end) return -1;
                int n=(int)Math.min(len,end-pos+1);
                for(int i=0;i<n;i++) b[off+i]=(byte)(pos++%251);
                return n;
            }
        };
    }
    private DashResumingInputStream.Segment segment(long start,long end,long total,long actualEnd,String etag,String url) {
        return new DashResumingInputStream.Segment(start,end,total,etag,url,bytes(start,actualEnd),()->{});
    }
    private long verify(InputStream stream,long start) throws Exception {
        byte[] buf=new byte[65536]; long pos=start; int n;
        while((n=stream.read(buf))>=0) for(int i=0;i<n;i++) assertEquals("byte "+pos,(int)(pos++%251),buf[i]&255);
        return pos-start;
    }
    @Test public void observedVideoTruncationResumesAtExactOffsetWithoutDuplicateBytes() throws Exception {
        long start=3109,total=70764838,received=41943647;
        AtomicInteger opens=new AtomicInteger();
        try(InputStream in=new DashResumingInputStream(segment(start,total-1,total,start+received-1,"v1","cdn1"),
                (offset,end,attempt)->{assertEquals(start+received,offset);opens.incrementAndGet();
                    return segment(offset,end,total,end,"v1","cdn1");},()->{},(a,o,c)->{})) {
            assertEquals(total-start,verify(in,start));
        }
        assertEquals(1,opens.get());
    }
    @Test public void audioAndVideoHaveIndependentOffsetsAndBudgets() throws Exception {
        for(long start:new long[]{0,127}) {
            try(InputStream in=new DashResumingInputStream(segment(start,999,1000,start+30,null,"same"),
                    (offset,end,attempt)->segment(offset,end,1000,end,null,"same"),()->{},(a,o,c)->{})) {
                assertEquals(1000-start,verify(in,start));
            }
        }
    }
    @Test public void failedConnectionsAndZeroProgressHaveFiniteBudget() throws Exception {
        for(boolean failOpen:new boolean[]{true,false}) {
            AtomicInteger opens=new AtomicInteger();
            try(InputStream in=new DashResumingInputStream(segment(0,100,101,-1,"e","one"),
                    (o,e,a)->{opens.incrementAndGet();if(failOpen)throw new IOException();return segment(o,e,101,o-1,"e","one");},()->{},(a,o,c)->{})) {
                try { in.read(); fail(); } catch(IOException expected) { }
            }
            assertEquals(3,opens.get());
        }
    }
    @Test public void mismatchCannotSpliceDifferentRepresentationOrRange() throws Exception {
        for(int variant=0;variant<5;variant++) {
            final int v=variant;
            try(InputStream in=new DashResumingInputStream(segment(0,99,100,9,"v1","one"),
                    (o,e,a)->segment(v==0?o+1:o,v==1?e-1:e,v==2?101:100,e,v==3?"v2":v==4?null:"v1","two"),()->{},(a,o,c)->{})) {
                assertEquals(10,in.read(new byte[20]));
                try { in.read(); fail(); } catch(DashResumingInputStream.InvalidRange expected) { }
            }
        }
    }
    @Test public void mirrorsRequireSharedStrongValidator() throws Exception {
        for(String etag:new String[]{null,"same-etag"}) {
            try(InputStream in=new DashResumingInputStream(segment(0,99,100,9,etag,"one"),
                    (o,e,a)->segment(o,e,100,e,etag,"two"),()->{},(a,o,c)->{})) {
                if(etag==null) { in.read(new byte[10]); try {in.read();fail();}catch(DashResumingInputStream.InvalidRange expected){} }
                else assertEquals(100,verify(in,0));
            }
        }
    }
    @Test public void changedSessionAndCancelledConsumerNeverReconnect() throws Exception {
        AtomicBoolean cancelled=new AtomicBoolean();AtomicInteger opens=new AtomicInteger();
        InputStream in=new DashResumingInputStream(segment(0,99,100,9,"e","one"),
                (o,e,a)->{opens.incrementAndGet();throw new IOException();},
                ()->{if(cancelled.get())throw new ProviderMediaEpoch.Changed();},(a,o,c)->{});
        in.read(new byte[10]);cancelled.set(true);
        try{in.read();fail();}catch(ProviderMediaEpoch.Changed expected){}
        in.close();assertEquals(0,opens.get());
        try{in.read();fail();}catch(IOException expected){}
    }
    @Test public void downstreamFailureClosesUpstreamWithoutRetry() throws Exception {
        AtomicInteger opens=new AtomicInteger();
        InputStream in=new DashResumingInputStream(segment(0,99,100,9,null,"one"),
                (o,e,a)->{opens.incrementAndGet();throw new IOException();},()->{},(a,o,c)->{});
        try { MediaRelay.write(new BufferedOutputStream(new OutputStream(){public void write(int b)throws IOException{throw new IOException();}}),
                    new byte[]{1},in,100,false,MediaRelay.QUIET);fail(); }
        catch(MediaRelay.Failure expected){assertEquals("client_transport_interrupted",expected.category);}
        assertEquals(0,opens.get());
    }
    @Test public void ordinaryEOFNeverReconnects() throws Exception {
        try(InputStream in=new DashResumingInputStream(segment(0,99,100,99,null,"one"),
                (o,e,a)->{throw new AssertionError("natural EOF retried");},()->{},(a,o,c)->{})) {
            assertEquals(100,verify(in,0));assertEquals(-1,in.read());
        }
    }
}
