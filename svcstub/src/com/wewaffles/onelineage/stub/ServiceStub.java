package com.wewaffles.onelineage.stub;

import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;

import java.lang.reflect.Method;

/**
 * Registers placeholder binder services under the given names and stays alive.
 *
 * While the guest runs, One UI's system_server is gone, but host daemons still
 * look up services it used to publish, and a missing service makes each lookup
 * block for the full 5 s getService() timeout:
 *  - audioserver asks for "CustomFrequencyManagerService" (NativeSemDvfsManager)
 *    on every track start and on its mixer thread: every sound started ~5 s late.
 *  - cameraserver asks for Knox' "edmnativehelper" on every camera open.
 *
 * A bare "name" registers a plain Binder: lookups return at once and every call
 * fails with UNKNOWN_TRANSACTION, which callers handle like a NULL service.
 * "name:value" answers every call with a bare int32 value instead, for services
 * whose clients read a failed call as "no" - edmnativehelper's is*Enabled /
 * is*Allowed checks treat an error as "disabled by policy" but a NULL service as
 * allowed, so it has to answer 1.
 *
 * "keep:name" saves the binder currently registered under name, and puts it
 * back once RESTORE_TRIGGER appears, then exits. The guest's own vold replaces
 * the host's "vold" registration, and the host vold can't be restarted to
 * re-register (init reboots the phone: "reboot,vold-failed"); without it One UI
 * fails vold.commitChanges() and reboots with "checkpoint_commit_failed".
 *
 * usage: CLASSPATH=svcstub.dex app_process /system/bin \
 *            com.wewaffles.onelineage.stub.ServiceStub <name[:int] | keep:name>...
 */
public final class ServiceStub {
    /** Answers every call transaction with the same raw int32. */
    static final class AnswerBinder extends Binder {
        private final int answer;

        AnswerBinder(String descriptor, int answer) {
            super(descriptor);
            this.answer = answer;
        }

        @Override
        protected boolean onTransact(int code, Parcel data, Parcel reply, int flags)
                throws android.os.RemoteException {
            if (code >= FIRST_CALL_TRANSACTION && code <= LAST_CALL_TRANSACTION) {
                if (reply != null) {
                    reply.writeInt(answer);
                }
                return true;
            }
            return super.onTransact(code, data, reply, flags);
        }
    }

    static final String RESTORE_TRIGGER = "/data/local/tmp/svcstub.restore";

    public static void main(String[] args) throws Exception {
        // ServiceManager is hidden API; app_process runs without the hidden API
        // restrictions that apply to apps.
        Class<?> sm = Class.forName("android.os.ServiceManager");
        Method add = sm.getMethod("addService", String.class, IBinder.class);
        Method check = sm.getMethod("checkService", String.class);
        java.util.Map<String, IBinder> kept = new java.util.LinkedHashMap<>();
        for (String arg : args) {
            if (arg.startsWith("keep:")) {
                String name = arg.substring(5);
                IBinder b = (IBinder) check.invoke(null, name);
                if (b != null) {
                    kept.put(name, b);
                    System.out.println("kept " + name);
                } else {
                    System.out.println("not registered, not kept: " + name);
                }
                continue;
            }
            int colon = arg.indexOf(':');
            String name = colon < 0 ? arg : arg.substring(0, colon);
            IBinder binder = colon < 0
                    ? new Binder(name)
                    : new AnswerBinder(name, Integer.parseInt(arg.substring(colon + 1)));
            add.invoke(null, name, binder);
            System.out.println("registered " + arg);
        }
        // app_process already started the binder thread pool; just wait here.
        java.io.File trigger = new java.io.File(RESTORE_TRIGGER);
        trigger.delete();
        while (true) {
            Thread.sleep(500);
            if (kept.isEmpty() || !trigger.exists()) {
                continue;
            }
            for (java.util.Map.Entry<String, IBinder> e : kept.entrySet()) {
                try {
                    add.invoke(null, e.getKey(), e.getValue());
                    System.out.println("restored " + e.getKey());
                } catch (Exception ex) {
                    System.out.println("restore failed for " + e.getKey() + ": " + ex.getCause());
                }
            }
            trigger.delete();
            System.out.flush();
            System.exit(0);
        }
    }
}
