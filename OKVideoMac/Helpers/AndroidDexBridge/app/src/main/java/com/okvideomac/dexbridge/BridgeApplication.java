package com.okvideomac.dexbridge;

import android.app.Application;

import com.github.catvod.Init;

public final class BridgeApplication extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        Init.set(this);
    }
}
