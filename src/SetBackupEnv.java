import java.lang.reflect.Method;

public class SetBackupEnv {
    static void log(String msg) {
        System.out.println(msg);
        try {
            Class<?> logClass = Class.forName("android.util.Log");
            Method d = logClass.getMethod("d", String.class, String.class);
            d.invoke(null, "BackupEnv", msg);
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

            String backupScript = "usb start; " +
                "sleep 1; " +
                "store read 0x10000000 boot_b 0 0x4000000; " +
                "fatwrite usb 0:1 0x10000000 boot_b.img 0x4000000; " +
                "fatwrite usb 1:1 0x10000000 boot_b.img 0x4000000; " +
                "store read 0x10000000 boot_a 0 0x4000000; " +
                "fatwrite usb 0:1 0x10000000 boot_a.img 0x4000000; " +
                "fatwrite usb 1:1 0x10000000 boot_a.img 0x4000000; " +
                "store read 0x10000000 vendor_boot_b 0 0x1800000; " +
                "fatwrite usb 0:1 0x10000000 vendor_boot_b.img 0x1800000; " +
                "fatwrite usb 1:1 0x10000000 vendor_boot_b.img 0x1800000; " +
                "store read 0x10000000 dtbo_b 0 0x200000; " +
                "fatwrite usb 0:1 0x10000000 dtbo_b.img 0x200000; " +
                "fatwrite usb 1:1 0x10000000 dtbo_b.img 0x200000; " +
                "store read 0x10000000 vbmeta_b 0 0x200000; " +
                "fatwrite usb 0:1 0x10000000 vbmeta_b.img 0x200000; " +
                "fatwrite usb 1:1 0x10000000 vbmeta_b.img 0x200000; " +
                "setenv bootcmd run storeboot; " +
                "saveenv; " +
                "run storeboot";

            log("Writing backup_cmd: " + backupScript);
            setBootenv.invoke(scm, "ubootenv.var.backup_cmd", backupScript);

            String verifyBackup = (String) getBootenv.invoke(scm, "ubootenv.var.backup_cmd", "");
            log("VERIFY backup_cmd = [" + verifyBackup + "]");

            String bootcmd = "run backup_cmd";
            log("Setting bootcmd: " + bootcmd);
            setBootenv.invoke(scm, "ubootenv.var.bootcmd", bootcmd);

            String verifyBootcmd = (String) getBootenv.invoke(scm, "ubootenv.var.bootcmd", "");
            log("VERIFY bootcmd = [" + verifyBootcmd + "]");

        } catch (Exception e) {
            log("Exception: " + e.getMessage());
        }
    }
}
