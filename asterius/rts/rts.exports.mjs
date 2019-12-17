import * as rtsConstants from "./rts.constants.mjs";

export class Exports {
  constructor(
    memory,
    reentrancy_guard,
    symbol_table,
    scheduler,
    tracer,
    exports,
    stableptr_manager
  ) {
    this.context = Object.freeze({
      memory: memory,
      reentrancyGuard: reentrancy_guard,
      symbolTable: symbol_table,
      scheduler: scheduler,
      tracer: tracer,
      stablePtrManager: stableptr_manager
    });
    Object.assign(this, exports);
    scheduler.run(this);
  }

  rts_eval(p) {
    return this.context.scheduler.submitCmdCreateThread("createGenThread", p);
  }

  rts_evalIO(p) {
    return this.context.scheduler.submitCmdCreateThread(
      "createStrictIOThread",
      p
    );
  }

  rts_evalLazyIO(p) {
    return this.context.scheduler.submitCmdCreateThread("createIOThread", p);
  }

  main() {
    return this.rts_evalLazyIO(
      this.rts_apply(
        this.context.symbolTable.base_AsteriusziTopHandler_runMainIO_closure,
        this.context.symbolTable.Main_main_closure
      )
    );
  }
}
