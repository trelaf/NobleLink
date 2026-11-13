// Create (if needed) and decompile functions at the given addresses.
// Usage (headless, -process on an existing project): -postScript DecompileAt.java <outDir> <hexAddr>...
//@category FlySky

import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;

import ghidra.app.cmd.disassemble.ArmDisassembleCommand;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

public class DecompileAt extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        File outDir = new File(args[0]);
        outDir.mkdirs();
        DecompInterface ifc = new DecompInterface();
        ifc.openProgram(currentProgram);
        for (int i = 1; i < args.length; i++) {
            Address a = toAddr(Long.parseUnsignedLong(args[i], 16) & ~1L);
            Function f = getFunctionAt(a);
            if (f == null) {
                new ArmDisassembleCommand(a, null, true).applyTo(currentProgram, monitor);
                f = createFunction(a, null);
            }
            if (f == null) {
                println("DecompileAt: could not create function at " + a);
                continue;
            }
            DecompileResults res = ifc.decompileFunction(f, 120, monitor);
            PrintWriter w = new PrintWriter(new FileWriter(new File(outDir, a.toString() + "_" + f.getName() + ".c")));
            w.println("// " + f.getName() + " @ " + a + " size " + f.getBody().getNumAddresses());
            w.println(res.decompileCompleted() ? res.getDecompiledFunction().getC() : "// decompile failed");
            w.close();
            println("DecompileAt: " + a + " -> " + f.getName());
        }
        ifc.dispose();
    }
}
