#include <AudioToolbox/AudioToolbox.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static OSStatus silence(void *ref,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *ts,UInt32 bus,UInt32 frames,AudioBufferList *list){for(UInt32 i=0;i<list->mNumberBuffers;i++)memset(list->mBuffers[i].mData,0,list->mBuffers[i].mDataByteSize);return noErr;}
int main(){AudioComponentDescription d={kAudioUnitType_Output,kAudioUnitSubType_DefaultOutput,kAudioUnitManufacturer_Apple,0,0};AudioUnit u;OSStatus a=AudioComponentInstanceNew(AudioComponentFindNext(NULL,&d),&u);AURenderCallbackStruct c={silence,NULL};OSStatus b=AudioUnitSetProperty(u,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&c,sizeof(c));OSStatus i=AudioUnitInitialize(u),s=AudioOutputUnitStart(u);printf("create=%d callback=%d initialize=%d start=%d\n",(int)a,(int)b,(int)i,(int)s);sleep(1);AudioOutputUnitStop(u);AudioComponentInstanceDispose(u);return s!=0;}
