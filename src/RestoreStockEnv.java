import java.lang.reflect.Method;

public class RestoreStockEnv {
    static void log(String msg) {
        System.out.println(msg);
        try {
            Class<?> logClass = Class.forName("android.util.Log");
            Method d = logClass.getMethod("d", String.class, String.class);
            d.invoke(null, "RestoreStockEnv", msg);
        } catch (Exception ignored) {}
    }

    public static void main(String[] args) {
        String action = (args != null && args.length > 0) ? args[0] : "flash_stock";
        log("RestoreStockEnv action: " + action);

        try {
            Class<?> scmClass = Class.forName("com.droidlogic.app.SystemControlManager");
            Object scm = scmClass.getMethod("getInstance").invoke(null);
            if (scm == null) {
                log("ERROR: SystemControlManager is null");
                return;
            }
            Method getBootenv = scmClass.getMethod("getBootenv", String.class, String.class);
            Method setBootenv = scmClass.getMethod("setBootenv", String.class, String.class);

            log("Connected to SystemControlManager");

            if ("slot_a".equalsIgnoreCase(action)) {
                log("Switching active_slot to _a (Factory Untouched Slot)");
                setBootenv.invoke(scm, "ubootenv.var.active_slot", "_a");
                setBootenv.invoke(scm, "ubootenv.var.bootcmd", "run storeboot");
                log("VERIFY active_slot = " + getBootenv.invoke(scm, "ubootenv.var.active_slot", ""));
                log("VERIFY bootcmd = " + getBootenv.invoke(scm, "ubootenv.var.bootcmd", ""));
            } else if ("relock".equalsIgnoreCase(action)) {
                log("Setting lock to locked (10101000) and SELinux to enforcing");
                setBootenv.invoke(scm, "ubootenv.var.lock", "10101000");
                setBootenv.invoke(scm, "ubootenv.var.EnableSelinux", "enforcing");
                setBootenv.invoke(scm, "ubootenv.var.bootcmd", "run storeboot");
                log("VERIFY lock = " + getBootenv.invoke(scm, "ubootenv.var.lock", ""));
                log("VERIFY EnableSelinux = " + getBootenv.invoke(scm, "ubootenv.var.EnableSelinux", ""));
            } else {
                // Default: flash_stock via U-Boot
                // Searches USB for stock_boot_b.img (or boot_b_stock.img or boot_b.img)
                String restoreScript = "usb start; " +
                    "sleep 2; " +
                    "setenv loaded 0; " +
                    "if fatload usb 0:1 0x10000000 stock_boot_b.img; then setenv loaded 1; fi; " +
                    "if fatload usb 1:1 0x10000000 stock_boot_b.img; then setenv loaded 1; fi; " +
                    "if fatload usb 0:1 0x10000000 boot_b_stock.img; then setenv loaded 1; fi; " +
                    "if fatload usb 1:1 0x10000000 boot_b_stock.img; then setenv loaded 1; fi; " +
                    "if load usb 0:1 0x10000000 stock_boot_b.img; then setenv loaded 1; fi; " +
                    "if load usb 1:1 0x10000000 stock_boot_b.img; then setenv loaded 1; fi; " +
                    "if test ${loaded} = 1; then store write 0x10000000 boot_b 0 0x4000000; fi; " +
                    "setenv bootcmd run storeboot; " +
                    "saveenv; " +
                    "run storeboot";

                log("Writing restore_cmd: " + restoreScript);
                setBootenv.invoke(scm, "ubootenv.var.restore_cmd", restoreScript);

                String verifyRestore = (String) getBootenv.invoke(scm, "ubootenv.var.restore_cmd", "");
                log("VERIFY restore_cmd = [" + verifyRestore + "]");

                String bootcmd = "run restore_cmd";
                log("Setting bootcmd: " + bootcmd);
                setBootenv.invoke(scm, "ubootenv.var.bootcmd", bootcmd);

                String verifyBootcmd = (String) getBootenv.invoke(scm, "ubootenv.var.bootcmd", "");
                log("VERIFY bootcmd = [" + verifyBootcmd + "]");
            }

        } catch (Exception e) {
            log("Exception: " + e.getMessage());
        }
    }
}
