import performance from "perf_hooks";

export class Tracer {
  constructor(logger, syms) {
    this.logger = logger;
    this.symbolLookupTable = {};
    for (const [k, v] of Object.entries(syms)) this.symbolLookupTable[v] = k;
    this.gsStats = {gc_wall_ms: 0, num_minor_GCs: 0, num_major_GCs: 0};
    Object.freeze(this);
  }

  traceCmm(f) {
    this.logger.logInfo(["call", f, this.symbolLookupTable[f]]);
  }

  traceCmmBlock(f, lbl) {
    this.logger.logInfo(["br", f, this.symbolLookupTable[f], lbl]);
  }

  traceCmmSetLocal(f, i, v) {
    this.logger.logInfo([
      "set_local",
      f,
      this.symbolLookupTable[f],
      i,
      v,
      this.symbolLookupTable[v]
    ]);
  }

  traceInitDone() {
    this.gsStats.init_wall_ms = performance.performance.now();
  }

  traceMinorGC(beginTime) {
    this.gsStats.gc_wall_ms += performance.performance.now() - beginTime;
    this.gsStats.num_minor_GCs += 1;
  }

  traceMajorGC(beginTime) {
    this.gsStats.gc_wall_ms += performance.performance.now() - beginTime;
    this.gsStats.num_major_GCs += 1;
  }

  displayGCStatistics() {
    var total_wall_ms = performance.performance.now();
    var gc_wall_ms = this.gsStats.gc_wall_ms;
    var mutator_wall_ms = total_wall_ms - gc_wall_ms - this.gsStats.init_wall_ms;
    console.log("Garbage Collection Statistics", {
      num_major_GCs: this.gsStats.num_major_GCs,
      num_minor_GCs: this.gsStats.num_minor_GCs,
      init_wall_seconds: this.gsStats.init_wall_ms / 1000.0,
      mutator_wall_seconds: mutator_wall_ms / 1000.0,
      GC_wall_seconds: gc_wall_ms / 1000.0,
    });
  }
}
