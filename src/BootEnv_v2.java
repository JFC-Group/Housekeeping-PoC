import java.lang.reflect.Method;

public class BootEnv {
    static void log(String msg) {
        System.out.println(msg);
        try {
            Class<?> logClass = Class.forName("android.util.Log");
            Method d = logClass.getMethod("d", String.class, String.class);
            d.invoke(null, "BootEnv", msg);
        } catch (Exception ignored) {}
    }

    public static void main(String[] args) {
        if (args.length < 1) { log("Usage: BootEnv read|set|unlock|lock [key] [value]"); return; }
        try {
            Class<?> scmClass = Class.forName("com.droidlogic.app.SystemControlManager");
            Object scm = scmClass.getMethod("getInstance").invoke(null);
            if (scm == null) { log("ERROR: SCM null"); return; }
            log("SCM connected");
            Method getBootenv = scmClass.getMethod("getBootenv", String.class, String.class);
            Method setBootenv = scmClass.getMethod("setBootenv", String.class, String.class);

            String cmd = args[0];
            if ("read".equals(cmd)) {
                String key = args.length > 1 ? args[1] : "lock_state";
                if (!key.startsWith("ubootenv.var.")) key = "ubootenv.var." + key;
                String val = (String) getBootenv.invoke(scm, key, "");
                log(key + " = [" + val + "]");
            } else if ("set".equals(cmd) && args.length >= 3) {
                String key = args[1];
                String value = args[2];
                if (!key.startsWith("ubootenv.var.")) key = "ubootenv.var." + key;
                String before = (String) getBootenv.invoke(scm, key, "");
                log("BEFORE: " + key + " = [" + before + "]");
                setBootenv.invoke(scm, key, value);
                String after = (String) getBootenv.invoke(scm, key, "");
                log("AFTER:  " + key + " = [" + after + "]");
            } else if ("unlock".equals(cmd)) {
                setBootenv.invoke(scm, "ubootenv.var.lock_state", "unlock");
                log("lock_state set to unlock");
            } else if ("lock".equals(cmd)) {
                setBootenv.invoke(scm, "ubootenv.var.lock_state", "lock");
                log("lock_state set to lock");
            } else { log("Unknown: " + cmd); }
        } catch (Exception e) {
            log("ERROR: " + e.getClass().getName() + ": " + e.getMessage());
            Throwable c = e.getCause();
            if (c != null) log("CAUSE: " + c.getClass().getName() + ": " + c.getMessage());
        }
    }
}
