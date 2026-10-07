#include <mpv/client.h>
#include <assert.h>
#include <stdbool.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
static void check(int r) { if(r<0) { fprintf(stderr,"mpv error: %s\n",mpv_error_string(r)); abort(); } }
static int threads(void) {
    thread_act_array_t list; mach_msg_type_number_t n;
    assert(task_threads(mach_task_self(), &list, &n)==KERN_SUCCESS);
    for(unsigned i=0;i<n;i++) mach_port_deallocate(mach_task_self(),list[i]);
    vm_deallocate(mach_task_self(),(vm_address_t)list,n*sizeof(*list)); return n;
}
static uint64_t rss(void) {
    mach_task_basic_info_data_t i; mach_msg_type_number_t n=MACH_TASK_BASIC_INFO_COUNT;
    assert(task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&i,&n)==KERN_SUCCESS);
    return i.resident_size;
}
static mpv_handle *create(int bad_device) {
    mpv_handle *m=mpv_create(); assert(m);
    const char *opts[][2]={{"config","no"},{"terminal","no"},{"vo","null"},
        {"ao","coreaudio"},{"mute","yes"},{"idle","yes"},{"keep-open","yes"}};
    for(size_t i=0;i<sizeof(opts)/sizeof(opts[0]);i++) check(mpv_set_option_string(m,opts[i][0],opts[i][1]));
    if(getenv("OK_AUDIO_TEST_LOG")) check(mpv_set_option_string(m,"terminal","yes"));
    if(bad_device) check(mpv_set_option_string(m,"audio-device","coreaudio/OKVIDEOMAC_NONEXISTENT_DEVICE_18383"));
    check(mpv_initialize(m));
    mpv_node devices; check(mpv_get_property(m,"audio-device-list",MPV_FORMAT_NODE,&devices));
    mpv_free_node_contents(&devices); return m;
}
static double position(mpv_handle *m) { double t=-1; mpv_get_property(m,"time-pos",MPV_FORMAT_DOUBLE,&t); return t; }
static void progress(mpv_handle *m,double target) {
    double deadline=now()+12;
    while(now()<deadline) { if(position(m)>=target) return; mpv_wait_event(m,0.01); }
    fprintf(stderr,"Playback did not progress to %.2f (actual %.2f)\n",target,position(m)); abort();
}
static void command(mpv_handle *m,const char *a,const char *b,const char *c) { const char *v[]={a,b,c,NULL}; check(mpv_command(m,v)); }
static void load(mpv_handle *m,const char *file) {
    command(m,"loadfile",file,"replace");
    double deadline=now()+12;
    while(now()<deadline) {
        mpv_event *e=mpv_wait_event(m,0.01);
        if(e->event_id==MPV_EVENT_FILE_LOADED) return;
        if(e->event_id==MPV_EVENT_END_FILE) {
            mpv_event_end_file *end=e->data;
            // Replacing a playing file emits STOP for the previous file first.
            assert(end->reason==MPV_END_FILE_REASON_STOP);
        }
    }
    abort();
}
int main(int argc,char **argv) {
    assert(argc==3);
    Dl_info info; assert(dladdr((void *)mpv_create,&info)); printf("loaded_libmpv=%s\n",info.dli_fname); fflush(stdout);
    uint64_t base_rss=0; int base_threads=0;
    for(int round=0;round<60;round++) {
        mpv_handle *m=create(0); load(m,argv[1]); progress(m,0.15);
        char *ao=mpv_get_property_string(m,"current-ao");
        if(!ao || strcmp(ao,"coreaudio")!=0) fprintf(stderr,"current-ao=%s\n",ao ? ao : "unavailable");
        assert(ao && strcmp(ao,"coreaudio")==0); mpv_free(ao);
        int pause=1; check(mpv_set_property(m,"pause",MPV_FORMAT_FLAG,&pause));
        double before=position(m); usleep(120000); double after=position(m); assert(after-before<0.06);
        pause=0; check(mpv_set_property(m,"pause",MPV_FORMAT_FLAG,&pause)); progress(m,before+0.12);
        command(m,"seek","2","absolute+exact"); progress(m,2.05);
        load(m,argv[2]); progress(m,0.1);
        command(m,"stop",NULL,NULL); mpv_terminate_destroy(m);
        if(round==9) { usleep(300000); base_rss=rss(); base_threads=threads(); }
    }
    for(int round=0;round<200;round++) { mpv_handle *m=create(0); mpv_terminate_destroy(m); }
    for(int round=0;round<20;round++) {
        mpv_handle *m=create(1); command(m,"loadfile",argv[2],"replace");
        bool failed=false; double deadline=now()+12;
        while(now()<deadline) { mpv_event *e=mpv_wait_event(m,0.01);
            if(e->event_id==MPV_EVENT_END_FILE) { mpv_event_end_file *end=e->data;
                assert(end->reason==MPV_END_FILE_REASON_ERROR); failed=true; break; } }
        assert(failed); mpv_terminate_destroy(m);
    }
    usleep(600000); uint64_t final_rss=rss(); int final_threads=threads();
    printf("rss_after_warmup=%llu rss_final=%llu threads_after_warmup=%d threads_final=%d\n",
        (unsigned long long)base_rss,(unsigned long long)final_rss,base_threads,final_threads);
    assert(final_rss<=base_rss+32*1024*1024); assert(final_threads<=base_threads+4);
    puts("PASS: 60 playback/pause/resume/seek/switch/destroy rounds; 200 enumerate/create/destroy; 20 invalid-device failures; bounded RSS/threads");
    return 0;
}
