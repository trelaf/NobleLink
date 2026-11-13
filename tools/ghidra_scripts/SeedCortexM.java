// Pre-analysis seeding for a raw Cortex-M image: turn on the aggressive ARM
// instruction finder and create Thumb functions at every vector-table target.
// Usage (headless pre-script): -preScript SeedCortexM.java
//@category FlySky

import java.math.BigInteger;

import ghidra.app.cmd.disassemble.ArmDisassembleCommand;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.mem.Memory;

public class SeedCortexM extends GhidraScript {
    @Override
    public void run() throws Exception {
        setAnalysisOption(currentProgram, "ARM Aggressive Instruction Finder", "true");
        Memory mem = currentProgram.getMemory();
        Address base = currentProgram.getMinAddress();
        long lo = base.getOffset();
        long hi = currentProgram.getMaxAddress().getOffset();
        int seeded = 0;
        for (int i = 1; i < 0x100; i++) {
            long v = mem.getInt(base.add(i * 4L)) & 0xffffffffL;
            if ((v & 1) == 0 || v < lo || v > hi) {
                continue;
            }
            Address target = toAddr(v & ~1L);
            ArmDisassembleCommand cmd = new ArmDisassembleCommand(target, null, true);
            cmd.applyTo(currentProgram, monitor);
            if (getFunctionAt(target) == null) {
                createFunction(target, null);
            }
            seeded++;
        }
        println("SeedCortexM: seeded " + seeded + " vector targets");
    }
}
