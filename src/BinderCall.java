import android.os.IBinder;
import android.os.Parcel;
import android.os.ServiceManager;
import android.content.Context;
import android.content.ComponentName;
import android.content.Intent;
import android.content.ServiceConnection;

public class BinderCall {
    static final String DESCRIPTOR = "com.jio.stb.jioservicelibrary.IJioServiceAidlInterface";

    public static void main(String[] args) throws Exception {
        System.out.println("uid=" + android.os.Process.myUid() + " pid=" + android.os.Process.myPid());
        
        // Try to find JioService via any registered binder
        // JioService is a bound service, not in ServiceManager directly.
        // But jio.nativeservice might be a proxy.
        String[] names = ServiceManager.listServices();
        System.out.println("Looking for Jio services...");
        for (String name : names) {
            if (name.toLowerCase().contains("jio") || name.toLowerCase().contains("stb")) {
                IBinder b = ServiceManager.getService(name);
                System.out.println("  " + name + " -> " + (b != null ? b.getInterfaceDescriptor() : "null"));
            }
        }

        // Try calling jio.nativeservice with our AIDL descriptor
        for (String svcName : new String[]{"jio.nativeservice", "jioservicenative"}) {
            IBinder binder = ServiceManager.getService(svcName);
            if (binder != null) {
                System.out.println("\nTrying " + svcName + " (descriptor: " + binder.getInterfaceDescriptor() + ")");
                try {
                    String json = "{\"module\":\"bootloader\",\"api\":\"set_bootloader_lock_params\",\"transaction_id\":\"100\",\"args\":{\"lock\":false}}";
                    Parcel data = Parcel.obtain();
                    Parcel reply = Parcel.obtain();
                    data.writeInterfaceToken(binder.getInterfaceDescriptor());
                    data.writeString(json);
                    boolean ok = binder.transact(1, data, reply, 0);
                    if (ok) {
                        reply.readException();
                        String result = reply.readString();
                        System.out.println("Result: " + result);
                    } else {
                        System.out.println("transact returned false");
                    }
                    reply.recycle();
                    data.recycle();
                } catch (Exception e) {
                    System.out.println("Error: " + e.getMessage());
                }
            }
        }
    }
}
