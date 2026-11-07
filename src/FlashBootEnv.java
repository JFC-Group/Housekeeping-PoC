import java.lang.reflect.Method;

public class FlashBootEnv {
    static void log(String msg) {
        System.out.println(msg);
        try {
            Class<?> logClass = Class.forName("android.util.Log");
            Method d = logClass.getMethod("d", String.class, String.class);
            d.invoke(null, "FlashBootEnv", msg);
        } catch (Exception ignored) {}
    }

    public static void main(String[] args) {
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

            // Failsafe flash command:
            // 1. Initialize USB subsystem
            // 2. Set guard loaded flag to 0
            // 3. Check /cache/boot_b.img (ext4 mmc 1:2)
            // 4. Check USB drive port 0 and port 1 for boot_b.img
            // 5. ONLY execute store write if loaded == 1
            // 6. Reset bootcmd back to 'run storeboot'
            // 7. Save environment permanently to eMMC
            // 8. Run storeboot to boot system
            String flashScript = "usb start; " +
                "sleep 2; " +
                "setenv loaded 0; " +
                "if ext4load mmc 1:2 0x10000000 /boot_b.img; then setenv loaded 1; fi; " +
                "if fatload usb 0:1 0x10000000 boot_b.img; then setenv loaded 1; fi; " +
                "if fatload usb 1:1 0x10000000 boot_b.img; then setenv loaded 1; fi; " +
                "if load usb 0:1 0x10000000 boot_b.img; then setenv loaded 1; fi; " +
                "if load usb 1:1 0x10000000 boot_b.img; then setenv loaded 1; fi; " +
                "if test ${loaded} = 1; then store write 0x10000000 boot_b 0 0x4000000; fi; " +
                "setenv bootcmd run storeboot; " +
                "saveenv; " +
                "run storeboot";

            log("Writing flash_cmd: " + flashScript);
            setBootenv.invoke(scm, "ubootenv.var.flash_cmd", flashScript);

            String verifyFlash = (String) getBootenv.invoke(scm, "ubootenv.var.flash_cmd", "");
            log("VERIFY flash_cmd = [" + verifyFlash + "]");

            String bootcmd = "run flash_cmd";
            log("Setting bootcmd: " + bootcmd);
            setBootenv.invoke(scm, "ubootenv.var.bootcmd", bootcmd);

            String verifyBootcmd = (String) getBootenv.invoke(scm, "ubootenv.var.bootcmd", "");
            log("VERIFY bootcmd = [" + verifyBootcmd + "]");

        } catch (Exception e) {
            log("Exception: " + e.getMessage());
        }
    }
}
