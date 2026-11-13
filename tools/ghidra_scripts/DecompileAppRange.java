// Decompile every function inside an address range to individual .c files.
// Usage (headless post-script):
//   -postScript DecompileAppRange.java <outDir> <startHex> <endHex>
// Functions whose demangled name starts with a vendored-library prefix are skipped.
//@category FlySky

import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileOptions;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;

public class DecompileAppRange extends GhidraScript {

    private static final String[] SKIP = {
        "TencentCloud", "Json::", "QFtp", "QUrlInfo", "Mime", "Smtp", "QuotedPrintable",
        "EmailAddress", "std::", "QList<", "QMap<", "QVector<", "QHash<", "QtPrivate",
        "QtMetaTypePrivate", "Sms::", "ses::"
    };

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        File outDir = new File(args[0]);
        outDir.mkdirs();
        Address start = toAddr(Long.parseUnsignedLong(args[1], 16));
        Address end = toAddr(Long.parseUnsignedLong(args[2], 16));

        DecompInterface ifc = new DecompInterface();
        DecompileOptions opts = new DecompileOptions();
        ifc.setOptions(opts);
        ifc.openProgram(currentProgram);

        PrintWriter index = new PrintWriter(new FileWriter(new File(outDir, "_index.tsv")));
        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(start, true);
        int done = 0, skipped = 0, failed = 0;
        while (it.hasNext() && !monitor.isCancelled()) {
            Function f = it.next();
            Address entry = f.getEntryPoint();
            if (entry.compareTo(end) >= 0) {
                break;
            }
            String full = f.getName(true);
            boolean skip = false;
            for (String s : SKIP) {
                if (full.startsWith(s)) {
                    skip = true;
                    break;
                }
            }
            if (skip) {
                skipped++;
                continue;
            }
            DecompileResults res = ifc.decompileFunction(f, 180, monitor);
            String safe = full.replaceAll("[^A-Za-z0-9_.~-]", "_");
            if (safe.length() > 120) {
                safe = safe.substring(0, 120);
            }
            String fileName = entry.toString() + "_" + safe + ".c";
            index.println(entry.toString() + "\t" + f.getBody().getNumAddresses() + "\t" + full
                + "\t" + fileName);
            if (res == null || !res.decompileCompleted()) {
                failed++;
                continue;
            }
            PrintWriter w = new PrintWriter(new FileWriter(new File(outDir, fileName)));
            w.println("// " + full + " @ " + entry.toString());
            w.println(res.getDecompiledFunction().getC());
            w.close();
            done++;
        }
        index.close();
        ifc.dispose();
        println("DecompileAppRange: decompiled=" + done + " skipped=" + skipped + " failed=" + failed);
    }
}
