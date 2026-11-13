// Decompile every function in the program into one .c file per function.
// Usage (headless post-script): -postScript DecompileAll.java <outDir>
//@category FlySky

import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;

public class DecompileAll extends GhidraScript {
    @Override
    public void run() throws Exception {
        File outDir = new File(getScriptArgs()[0]);
        outDir.mkdirs();
        DecompInterface ifc = new DecompInterface();
        ifc.openProgram(currentProgram);
        PrintWriter index = new PrintWriter(new FileWriter(new File(outDir, "_index.tsv")));
        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        int done = 0, failed = 0;
        while (it.hasNext() && !monitor.isCancelled()) {
            Function f = it.next();
            DecompileResults res = ifc.decompileFunction(f, 120, monitor);
            String entry = f.getEntryPoint().toString();
            index.println(entry + "\t" + f.getBody().getNumAddresses() + "\t" + f.getName());
            if (res == null || !res.decompileCompleted()) {
                failed++;
                continue;
            }
            PrintWriter w = new PrintWriter(new FileWriter(new File(outDir, entry + "_" + f.getName() + ".c")));
            w.println("// " + f.getName() + " @ " + entry + " size " + f.getBody().getNumAddresses());
            w.println(res.getDecompiledFunction().getC());
            w.close();
            done++;
        }
        index.close();
        ifc.dispose();
        println("DecompileAll: decompiled=" + done + " failed=" + failed);
    }
}
